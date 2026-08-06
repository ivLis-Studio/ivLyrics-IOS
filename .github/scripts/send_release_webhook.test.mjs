import assert from 'node:assert/strict';
import test from 'node:test';

import {
  DISCORD_RELEASE_NOTES_CHUNK_SIZE,
  buildReleaseWebhookMessages,
  normalizeDiscordWebhookUrl,
  postReleaseWebhookMessage,
  splitReleaseNotes
} from './send_release_webhook.mjs';

test('release notes are split without dropping content', () => {
  const notes = `# Changes\n\n${'A'.repeat(DISCORD_RELEASE_NOTES_CHUNK_SIZE)}🍎\n마지막 줄`;
  const chunks = splitReleaseNotes(notes);

  assert.ok(chunks.length > 1);
  assert.ok(chunks.every(chunk => chunk.length <= DISCORD_RELEASE_NOTES_CHUNK_SIZE));
  assert.ok(chunks.every(chunk => !/[\uD800-\uDBFF]$|^[\uDC00-\uDFFF]/.test(chunk)));
  assert.equal(chunks.join(''), notes);

  const emojiBoundary = splitReleaseNotes(`${'A'.repeat(4)}🍎B`, 5);
  assert.deepEqual(emojiBoundary, ['AAAA', '🍎B']);
});

test('each platform has an unmistakable heading and color', () => {
  const expected = {
    pc: ['PC Update', 0x8B5CF6, 'PC'],
    android: ['Android Update', 0x3DDC84, 'Android'],
    ios: ['iOS Update', 0x0A84FF, 'iOS']
  };

  for (const [platform, [heading, color, label]] of Object.entries(expected)) {
    const [message] = buildReleaseWebhookMessages({
      platform,
      tag: 'v1.2.3',
      title: 'Release title',
      body: 'Release body',
      releaseUrl: 'https://github.com/ivLis-Studio/example/releases/tag/v1.2.3',
      now: 0
    });
    assert.match(message.content, new RegExp(heading));
    assert.equal(message.embeds[0].color, color);
    assert.equal(message.embeds[0].fields[0].value, label);
    assert.deepEqual(message.allowed_mentions, { parse: [] });
  }
});

test('Discord webhook validation rejects unrelated hosts and enables response waiting', () => {
  assert.equal(normalizeDiscordWebhookUrl('https://example.com/api/webhooks/a/b'), null);
  assert.equal(
    normalizeDiscordWebhookUrl('https://discord.com/api/webhooks/123/token'),
    'https://discord.com/api/webhooks/123/token?wait=true'
  );
});

test('delivery retries a rate limit without exposing or changing the payload', async () => {
  const calls = [];
  const sleeps = [];
  await postReleaseWebhookMessage(
    'https://discord.com/api/webhooks/123/token?wait=true',
    { content: 'hello' },
    {
      fetchImpl: async (_url, init) => {
        calls.push(JSON.parse(init.body));
        return calls.length === 1
          ? new Response(JSON.stringify({ retry_after: 0.001 }), {
            status: 429,
            headers: { 'Content-Type': 'application/json' }
          })
          : new Response('{}', { status: 200 });
      },
      sleep: async milliseconds => sleeps.push(milliseconds)
    }
  );

  assert.deepEqual(calls, [{ content: 'hello' }, { content: 'hello' }]);
  assert.deepEqual(sleeps, [500]);
});
