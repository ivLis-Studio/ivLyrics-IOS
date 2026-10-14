import Foundation
#if canImport(llama)
import llama
#endif

extension LocalAIService {
    /// The app's single engine owner. Model files live in Application Support/LocalAI,
    /// which is excluded from iCloud backup.
    static let shared = LocalAIService(directory: LocalAIService.defaultDirectory, loader: LlamaInferenceEngine.loader)
}

#if canImport(llama)

/// llama.cpp b11364 (Metal) running one GGUF model. Calls block; LocalAIService makes them one at a
/// time on its engine queue. No UIKit here, so the same wrapper also builds and runs on macOS.
final class LlamaInferenceEngine: LocalAIInferenceEngine, @unchecked Sendable {
    static let loader: LocalAIEngineLoader? = { url, processor in
        try LlamaInferenceEngine.load(modelURL: url, processor: processor)
    }

    let usesGPU: Bool
    var deviceLabel: String { usesGPU ? "GPU" : "CPU" }

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let chatTemplate: LocalAI.ChatTemplateChoice
    private let contextLength: Int
    private let batchSize: Int

    /// The GPU first (all layers offloaded) unless CPU only was chosen; the CPU when the GPU fails.
    static func load(modelURL: URL, processor: LocalAI.Processor) throws -> LlamaInferenceEngine {
        LlamaBackend.prepare()
        if processor == .auto && llama_supports_gpu_offload() {
            do {
                return try LlamaInferenceEngine(path: modelURL.path, gpu: true)
            } catch {
                // A device whose GPU cannot hold the model still has the slower CPU path.
            }
        }
        return try LlamaInferenceEngine(path: modelURL.path, gpu: false)
    }

    private init(path: String, gpu: Bool) throws {
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpu ? -1 : 0
        modelParams.load_mode = LLAMA_LOAD_MODE_MMAP
        if !gpu {
            // Repacking copies the CPU weights out of the memory-mapped file: on an M4 Pro it took
            // 2.3 GB instead of 1.5 GB and was slower, so the CPU reads the mapped weights directly.
            modelParams.use_extra_bufts = false
        }
        let loadedModel: OpaquePointer?
        if gpu {
            loadedModel = llama_model_load_from_file(path, modelParams)
        } else {
            // An empty device list keeps every layer and operation on the CPU.
            var devices: [ggml_backend_dev_t?] = [nil]
            loadedModel = devices.withUnsafeMutableBufferPointer { buffer in
                modelParams.devices = buffer.baseAddress
                return llama_model_load_from_file(path, modelParams)
            }
        }
        guard let model = loadedModel else {
            throw LocalAIError.engine("The model could not be loaded.")
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = LocalAI.contextLength
        contextParams.n_batch = LocalAI.batchSize
        contextParams.n_ubatch = LocalAI.batchSize
        contextParams.n_seq_max = 1
        contextParams.n_threads = Self.threadCount
        contextParams.n_threads_batch = Self.threadCount
        contextParams.no_perf = true
        if !gpu {
            contextParams.offload_kqv = false
            contextParams.op_offload = false
        }
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LocalAIError.engine("Not enough memory to start the model.")
        }
        guard let template = llama_model_chat_template(model, nil) else {
            llama_free(context)
            llama_model_free(model)
            throw LocalAIError.engine("The model has no chat template.")
        }
        self.model = model
        self.context = context
        vocab = llama_model_get_vocab(model)
        chatTemplate = LocalAI.chatTemplateChoice(modelTemplate: String(cString: template))
        contextLength = Int(llama_n_ctx(context))
        batchSize = max(1, Int(llama_n_batch(context)))
        usesGPU = gpu
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// A sensible number of performance cores: min(4, cores).
    static let threadCount: Int32 = {
        var performanceCores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let cores = sysctlbyname("hw.perflevel0.physicalcpu", &performanceCores, &size, nil, 0) == 0 && performanceCores > 0
            ? Int(performanceCores)
            : ProcessInfo.processInfo.activeProcessorCount
        return Int32(max(1, min(4, cores)))
    }()

    func complete(prompt: String, maxTokens: Int, shouldStop: () -> Bool) throws -> LocalAI.Completion {
        let rendered = try render(prompt)
        // The template's own begin-of-sentence marker is already in the text.
        var tokens = try tokenize(rendered, addSpecial: chatTemplate.prefix.isEmpty)
        let room = contextLength - tokens.count
        guard !tokens.isEmpty, room > 1 else { throw LocalAIError.promptTooLong }
        let budget = max(1, min(maxTokens, room - 1))

        llama_memory_clear(llama_get_memory(context), true)
        let sampler = makeSampler(promptTokens: tokens)
        defer { llama_sampler_free(sampler) }

        var start = 0
        while start < tokens.count {
            if shouldStop() { throw CancellationError() }
            let end = min(tokens.count, start + batchSize)
            let status = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + start, Int32(end - start)))
            }
            guard status == 0 else { throw LocalAIError.engine("Decoding failed (\(status)).") }
            start = end
        }

        var output: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        var generated = 0
        var stoppedAtLimit = false
        while true {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            var count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if count < 0 {
                piece = [CChar](repeating: 0, count: Int(-count))
                count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            }
            if count > 0 {
                output.append(contentsOf: piece.prefix(Int(count)).map { UInt8(bitPattern: $0) })
            }
            generated += 1
            if generated >= budget {
                stoppedAtLimit = true
                break
            }
            if shouldStop() { throw CancellationError() }
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw LocalAIError.engine("Decoding failed (\(status)).") }
        }
        return LocalAI.Completion(text: String(decoding: output, as: UTF8.self), stoppedAtLimit: stoppedAtLimit)
    }

    /// One user message through the model's chat template; no system prompt.
    func render(_ prompt: String) throws -> String {
        let rendered: String? = "user".withCString { role in
            prompt.withCString { content in
                var message = llama_chat_message(role: role, content: content)
                var buffer = [CChar](repeating: 0, count: max(1024, prompt.utf8.count * 2 + 256))
                var length = llama_chat_apply_template(chatTemplate.template, &message, 1, true, &buffer, Int32(buffer.count))
                if length > Int32(buffer.count) {
                    buffer = [CChar](repeating: 0, count: Int(length) + 1)
                    length = llama_chat_apply_template(chatTemplate.template, &message, 1, true, &buffer, Int32(buffer.count))
                }
                guard length > 0 else { return nil }
                let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        guard let rendered else { throw LocalAIError.engine("The model's chat template is not supported.") }
        return chatTemplate.prefix + rendered
    }

    private func tokenize(_ text: String, addSpecial: Bool) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: text.utf8.count + 8)
        var count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addSpecial, true)
        if count < 0 {
            guard count != Int32.min else { throw LocalAIError.promptTooLong }
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addSpecial, true)
        }
        guard count >= 0 else { throw LocalAIError.engine("The prompt could not be tokenized.") }
        return Array(tokens.prefix(Int(count)))
    }

    /// Model-card sampling in llama.cpp's default order; the prompt fills the repeat-penalty window
    /// as it does on PC.
    private func makeSampler(promptTokens: [llama_token]) -> UnsafeMutablePointer<llama_sampler> {
        var params = llama_sampler_chain_default_params()
        params.no_perf = true
        let chain = llama_sampler_chain_init(params)!
        let sampling = LocalAI.sampling
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), sampling.penaltyLastN,
                                                                    sampling.repeatPenalty, 0, 0))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(sampling.topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(sampling.topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(sampling.minP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(sampling.temperature))
        // LLAMA_DEFAULT_SEED: a random seed.
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.max))
        for token in promptTokens { llama_sampler_accept(chain, token) }
        return chain
    }
}

/// Process-wide llama.cpp setup: backends once, and only errors in the log.
private enum LlamaBackend {
    private static let ready: Void = {
        llama_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            fputs(text, stderr)
        }, nil)
        llama_backend_init()
    }()

    static func prepare() { _ = ready }
}

#else

/// iOS Simulator builds have no llama.cpp slice: Local AI reports that it is unavailable.
enum LlamaInferenceEngine {
    static let loader: LocalAIEngineLoader? = nil
}

#endif

