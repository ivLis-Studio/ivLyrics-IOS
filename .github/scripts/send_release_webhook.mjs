import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const DISCORD_RELEASE_NOTES_CHUNK_SIZE = 3800;

export const RELEASE_PLATFORM_CONFIG = Object.freeze({
  pc: Object.freeze({
    label: 'PC',
    heading: '🖥️ PC Update',
    color: 0x8B5CF6
  }),
  android: Object.freeze({
    label: 'Android',
    heading: '🤖 Android Update',
    color: 0x3DDC84
  }),
  ios: Object.freeze({
    label: 'iOS',
    heading: '🍎 iOS Update',
    color: 0x0A84FF
  })
});

function truncate(value, maxLength) {
  const text = String(value ?? '');
  if (text.length <= maxLength) return text;
  return `${text.slice(0, Math.max(0, maxLength - 1))}…`;
}

export function normalizeDiscordWebhookUrl(value) {
  try {
    const url = new URL(String(value || '').trim());
    const allowedHost = url.hostname === 'discord.com' || url.hostname === 'discordapp.com';
    if (
      url.protocol !== 'https:'
      || !allowedHost
      || !/^\/api\/webhooks\/[^/]+\/[^/]+/.test(url.pathname)
    ) {
      return null;
    }
    url.searchParams.set('wait', 'true');
    return url.toString();
  } catch {
    return null;
  }
}

export function splitReleaseNotes(value, maxLength = DISCORD_RELEASE_NOTES_CHUNK_SIZE) {
  if (!Number.isInteger(maxLength) || maxLength < 1 || maxLength > 4096) {
    throw new Error('Release note chunk length must be between 1 and 4096.');
  }

  const source = String(value ?? '') || 'No release notes were provided.';
  const chunks = [];
  let remaining = source;

  while (remaining.length > maxLength) {
    let splitAt = remaining.lastIndexOf('\n', maxLength + 1);
    if (splitAt < Math.floor(maxLength / 2)) {
      splitAt = maxLength;
    } else {
      splitAt += 1;
    }
    const previousCodeUnit = remaining.charCodeAt(splitAt - 1);
    const nextCodeUnit = remaining.charCodeAt(splitAt);
    if (
      previousCodeUnit >= 0xD800 && previousCodeUnit <= 0xDBFF
      && nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF
    ) {
      splitAt -= 1;
    }
    chunks.push(remaining.slice(0, splitAt));
    remaining = remaining.slice(splitAt);
  }

  if (remaining || chunks.length === 0) {
    chunks.push(remaining);
  }
  return chunks;
}

export function buildReleaseWebhookMessages({
  platform,
  tag,
  title,
  body,
  releaseUrl,
  now = Date.now()
}) {
  const config = RELEASE_PLATFORM_CONFIG[String(platform || '').toLowerCase()];
  if (!config) {
    throw new Error('RELEASE_PLATFORM must be pc, android, or ios.');
  }

  const normalizedReleaseUrl = new URL(String(releaseUrl || ''));
  if (normalizedReleaseUrl.protocol !== 'https:') {
    throw new Error('Release URL must use HTTPS.');
  }

  const chunks = splitReleaseNotes(body);
  const timestamp = new Date(now).toISOString();

  return chunks.map((description, index) => {
    const part = index + 1;
    const isFirst = index === 0;
    const partLabel = chunks.length > 1 ? ` • Part ${part}/${chunks.length}` : '';
    const embedTitle = isFirst
      ? `[${config.label}] ${title || tag}`
      : `[${config.label}] Release Notes ${part}/${chunks.length}`;

    return {
      username: 'ivLyrics Releases',
      allowed_mentions: { parse: [] },
      content: `**${config.heading} Released**${partLabel}`,
      embeds: [{
        title: truncate(embedTitle, 256),
        url: normalizedReleaseUrl.toString(),
        description,
        color: config.color,
        fields: [
          { name: 'Platform', value: config.label, inline: true },
          { name: 'Version', value: truncate(tag || 'Unknown', 1024), inline: true },
          { name: 'GitHub Release', value: `[Open release](${normalizedReleaseUrl.toString()})`, inline: false }
        ],
        footer: {
          text: chunks.length > 1
            ? `ivLyrics ${config.label} • Release notes ${part} of ${chunks.length}`
            : `ivLyrics ${config.label}`
        },
        timestamp
      }]
    };
  });
}

function getRetryDelayMs(response, payload, attempt) {
  const headerValue = Number(response.headers.get('retry-after'));
  const payloadValue = Number(payload?.retry_after);
  const seconds = Number.isFinite(headerValue) && headerValue > 0
    ? headerValue
    : (Number.isFinite(payloadValue) && payloadValue > 0 ? payloadValue : 2 ** attempt);
  return Math.min(30_000, Math.max(500, Math.ceil(seconds * 1000)));
}

export async function postReleaseWebhookMessage(webhookUrl, message, options = {}) {
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const sleep = options.sleep || (milliseconds => new Promise(resolveSleep => setTimeout(resolveSleep, milliseconds)));
  const maxAttempts = options.maxAttempts || 4;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const response = await fetchImpl(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(message)
    });
    if (response.ok) return;

    let responsePayload = null;
    if (response.status === 429) {
      try {
        responsePayload = await response.json();
      } catch {
        responsePayload = null;
      }
    }
    const retryable = response.status === 429 || response.status >= 500;
    if (!retryable || attempt === maxAttempts) {
      throw new Error(`Discord release webhook returned HTTP ${response.status}.`);
    }
    await sleep(getRetryDelayMs(response, responsePayload, attempt));
  }
}

export async function sendReleaseWebhook(env = process.env, options = {}) {
  const webhookUrl = normalizeDiscordWebhookUrl(env.RELEASE_WEBHOOK_URL);
  if (!webhookUrl) {
    throw new Error('RELEASE_WEBHOOK_URL is missing or is not a Discord webhook URL.');
  }

  const platform = String(env.RELEASE_PLATFORM || '').toLowerCase();
  const tag = String(env.RELEASE_TAG || '').trim();
  const title = String(env.RELEASE_TITLE || '').trim();
  const notesPath = String(env.RELEASE_NOTES_PATH || '').trim();
  const repository = String(env.GITHUB_REPOSITORY || '').trim();
  if (!RELEASE_PLATFORM_CONFIG[platform] || !tag || !title || !notesPath || !repository) {
    throw new Error('Release webhook metadata is incomplete.');
  }

  const body = await readFile(notesPath, 'utf8');
  const releaseUrl = `https://github.com/${repository}/releases/tag/${encodeURIComponent(tag)}`;
  const messages = buildReleaseWebhookMessages({
    platform,
    tag,
    title,
    body,
    releaseUrl,
    now: options.now
  });

  for (let index = 0; index < messages.length; index += 1) {
    await postReleaseWebhookMessage(webhookUrl, messages[index], options);
    console.log(`Sent ${RELEASE_PLATFORM_CONFIG[platform].label} release notification ${index + 1}/${messages.length}.`);
  }
}

const entryPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : '';
if (entryPath === import.meta.url) {
  sendReleaseWebhook().catch(error => {
    console.error(error?.message || error);
    process.exitCode = 1;
  });
}
