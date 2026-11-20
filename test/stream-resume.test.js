// Mid-stream resume — the third arm of streamChatWithEmptyRetry, ported from
// WncFht/devin2api's tryResume. When the upstream stream dies AFTER producing
// content (STREAM_TRUNCATED / TIMEOUT / transport reset — exactly the
// isRetryable() set), the request is re-sent with the produced prefix echoed
// back as an assistant message plus a "continue" user message, and the
// upstream continues generation from the cut. The client's accumulated answer
// is kept — NO attempt_reset — so prefix + continuation read as one response.
//
// STREAMING ONLY: it fires inside streamChatCompletion via opts.streaming.
// A buffered client never saw the partial output, so whole-request retry
// (clean regenerate) remains the contract there — pinned by
// devin-connect-openai.test.js's "no token duplication" case.
//
// Budget semantics match the two sibling arms (#240 lesson): resume carries
// its OWN counter (DEVIN_CONNECT_STREAM_RESUME_MAX, default 2, ceiling 5), and
// each hop still passes the per-request turn budget at the loop head.

import { describe, it, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { toChatCompletion, __setStreamChatForTest, __testing } from '../src/devin-connect-openai.js';

const FINISH = { type: 'finish', reason: 'stop', usage: { completion_tokens: 3 } };
const TRUNCATED = () => Object.assign(new Error('stream ended'), { code: 'STREAM_TRUNCATED' });
const BLOCKED = () => Object.assign(new Error('content blocked'), { code: 'REQUEST_REJECTED' });

afterEach(() => {
  __setStreamChatForTest(null);
  delete process.env.DEVIN_CONNECT_STREAM_RESUME_MAX;
  delete process.env.DEVIN_CONNECT_RETRY_ON_EMPTY_MS;
});

/**
 * Drive streamChatWithEmptyRetry in streaming mode against scripted upstream
 * turns. A turn is `{ events: [...], err }` — events are yielded, then `err`
 * is thrown if set. The last entry repeats if more turns are asked for than
 * scripted. Returns every upstream call's params plus the yielded event list.
 */
async function run(turns, { env = {}, params } = {}) {
  process.env.DEVIN_CONNECT_RETRY_ON_EMPTY_MS = '0';
  for (const [k, v] of Object.entries(env)) process.env[k] = v;
  const calls = [];
  __setStreamChatForTest(async function* (p) {
    const turn = turns[Math.min(calls.length, turns.length - 1)];
    calls.push(p);
    for (const ev of turn.events || []) yield ev;
    if (turn.err) throw turn.err;
  });
  const events = [];
  await (async () => {
    for await (const ev of __testing.streamChatWithEmptyRetry(
      params || { model: 'swe-1-7', messages: [{ role: 'user', content: 'go' }] },
      undefined,
      { streaming: true },
    )) events.push(ev);
  })();
  const content = events.filter((e) => e.type === 'content').map((e) => e.text).join('');
  return { calls, events, content };
}

async function runErr(turns, opts = {}) {
  let thrown = null;
  try {
    await run(turns, opts);
  } catch (err) {
    thrown = err;
  }
  return thrown;
}

describe('mid-stream resume — happy path', () => {
  it('a truncation after content continues on the same logical answer', async () => {
    const r = await run([
      { events: [{ type: 'content', text: 'partial ' }], err: TRUNCATED() },
      { events: [{ type: 'content', text: 'continued' }, FINISH] },
    ]);
    assert.equal(r.content, 'partial continued',
      'prefix kept + continuation appended — the client never sees the seam');
    assert.equal(r.calls.length, 2);
    assert.equal(r.events.some((e) => e.type === 'attempt_reset'), false,
      'a resume CONTINUES the answer; nothing the client received is retracted');
  });

  it('the resume re-sends ORIGINAL messages + assistant echo + "continue", with tool_choice cleared', async () => {
    const r = await run([
      { events: [{ type: 'content', text: 'halfway ' }], err: TRUNCATED() },
      { events: [{ type: 'content', text: 'done' }, FINISH] },
    ], {
      params: {
        model: 'swe-1-7',
        messages: [{ role: 'user', content: 'go' }],
        tools: [{ type: 'function', function: { name: 'f', parameters: {} } }],
        toolChoice: { type: 'function', function: { name: 'f' } },
      },
    });
    const tail = r.calls[1].messages.slice(-2);
    assert.deepEqual(tail, [
      { role: 'assistant', content: 'halfway ' },
      { role: 'user', content: 'continue' },
    ]);
    assert.equal(r.calls[1].toolChoice, undefined,
      'devin2api measured a forced tool_choice makes upstream re-issue the same call each hop');
    // The original user turn is still there — the echo is appended, not substituted.
    assert.equal(r.calls[1].messages[0].content, 'go');
  });

  it('a second truncation resumes again with the ACCUMULATED prefix', async () => {
    const r = await run([
      { events: [{ type: 'content', text: 'a' }], err: TRUNCATED() },
      { events: [{ type: 'content', text: 'b' }], err: TRUNCATED() },
      { events: [{ type: 'content', text: 'c' }, FINISH] },
    ]);
    assert.equal(r.calls.length, 3);
    assert.equal(r.calls[2].messages.at(-2).content, 'ab',
      'each hop echoes everything produced so far — one echo, one continue');
    assert.equal(r.content, 'abc');
  });

  it('produced reasoning rides the echo as unsigned reasoning_content', async () => {
    const r = await run([
      { events: [{ type: 'reasoning', text: 'think ' }, { type: 'content', text: 'x' }], err: TRUNCATED() },
      { events: [{ type: 'content', text: 'y' }, FINISH] },
    ]);
    const echo = r.calls[1].messages.at(-2);
    assert.equal(echo.reasoning_content, 'think ');
    assert.equal(echo.content, 'x');
    assert.equal(r.content, 'xy');
  });
});

describe('mid-stream resume — gates', () => {
  it('pre-content death does NOT resume (nothing to echo)', async () => {
    const thrown = await runErr([{ events: [], err: TRUNCATED() }]);
    assert.equal(thrown?.code, 'STREAM_TRUNCATED');
  });

  it('non-retryable errors do NOT resume even after content (UPSTREAM_INTERNAL/REQUEST_REJECTED)', async () => {
    const thrown = await runErr([
      { events: [{ type: 'content', text: 'x' }], err: BLOCKED() },
    ]);
    assert.equal(thrown?.code, 'REQUEST_REJECTED');
  });

  it('the resume budget is spent and then the real upstream error surfaces', async () => {
    const calls = [];
    __setStreamChatForTest(async function* (p) {
      calls.push(p);
      yield { type: 'content', text: `seg${calls.length} ` };
      throw TRUNCATED();
    });
    process.env.DEVIN_CONNECT_RETRY_ON_EMPTY_MS = '0';
    process.env.DEVIN_CONNECT_STREAM_RESUME_MAX = '1';
    let thrown = null;
    try {
      for await (const _ev of __testing.streamChatWithEmptyRetry(
        { model: 'swe-1-7', messages: [{ role: 'user', content: 'go' }] }, undefined, { streaming: true })) { /* drain */ }
    } catch (err) {
      thrown = err;
    }
    assert.equal(thrown?.code, 'STREAM_TRUNCATED', 'after the cap the unmodified upstream error propagates');
    assert.equal(calls.length, 2, '1 original + 1 resume hop at RESUME_MAX=1');
    assert.equal(calls[1].messages.at(-2).content, 'seg1 ',
      'the resume hop echoes what the first segment produced');
  });
});

describe('mid-stream resume — non-stream stays on whole-request retry', () => {
  it('toChatCompletion still regenerates cleanly (pinned contract unchanged)', async () => {
    let calls = 0;
    __setStreamChatForTest(async function* () {
      calls++;
      if (calls === 1) {
        yield { type: 'content', text: 'PARTIAL' };
        throw Object.assign(new Error('reset'), { code: 'ECONNRESET' });
      }
      yield { type: 'content', text: 'clean answer' };
      yield FINISH;
    });
    const { body } = await toChatCompletion(
      { model: 'm', messages: [{ role: 'user', content: 'go' }] },
      { retryBaseMs: 1 },
    );
    assert.equal(body.choices[0].message.content, 'clean answer',
      'buffered path: the partial never crossed the wire, so a whole retry '
      + 'regenerates — resume must not bake the prefix into an echo here');
    assert.equal(calls, 2);
  });
});
