'use strict';

const http = require('node:http');

const USAGE = {
  input_tokens: 1,
  input_tokens_details: { cached_tokens: 0 },
  output_tokens: 1,
  output_tokens_details: { reasoning_tokens: 0 },
  total_tokens: 2,
};

function sse(res, type, payload) {
  res.write(`event: ${type}\n`);
  res.write(`data: ${JSON.stringify({ type, ...payload })}\n\n`);
}

function outputItem(spec, index, turn) {
  const id = `item_${turn}_${index}`;
  const callId = spec.callId || `call_${turn}_${index}`;
  const namespace = spec.namespace ? { namespace: spec.namespace } : {};
  switch (spec.type) {
    case 'message':
      return {
        type: 'message',
        id,
        status: 'completed',
        role: 'assistant',
        content: [{ type: 'output_text', text: spec.text, annotations: [] }],
      };
    case 'function_call':
      return {
        type: 'function_call',
        id,
        status: 'completed',
        call_id: callId,
        name: spec.name,
        arguments: typeof spec.arguments === 'string' ? spec.arguments : JSON.stringify(spec.arguments || {}),
        ...namespace,
      };
    case 'custom_tool_call':
      return {
        type: 'custom_tool_call',
        id,
        status: 'completed',
        call_id: callId,
        name: spec.name,
        input: spec.input,
        ...namespace,
      };
    default:
      throw new Error(`unknown output spec type: ${spec.type}`);
  }
}

function streamResponse(res, items, turn) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });
  sse(res, 'response.created', {
    response: { id: `resp_${turn}`, object: 'response', status: 'in_progress', output: [] },
  });
  items.forEach((item, index) => {
    sse(res, 'response.output_item.added', { output_index: index, item });
    if (item.type === 'message') {
      sse(res, 'response.output_text.delta', {
        item_id: item.id,
        output_index: index,
        content_index: 0,
        delta: item.content[0].text,
      });
    }
    sse(res, 'response.output_item.done', { output_index: index, item });
  });
  sse(res, 'response.completed', {
    response: {
      id: `resp_${turn}`,
      object: 'response',
      status: 'completed',
      output: items,
      usage: USAGE,
    },
  });
  res.end();
}

function startMockModel({ respond, onRequest = () => {}, onError = () => {} }) {
  let turn = 0;
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (req.method !== 'POST' || !/\/responses$/.test(req.url.split('?')[0])) {
        onRequest({ served: false, method: req.method, url: req.url, raw, body: null, turn: null });
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end('{"error":{"message":"not served by the probe mock"}}');
        return;
      }
      turn += 1;
      let body = {};
      try {
        body = JSON.parse(raw);
      } catch {
        body = {};
      }
      onRequest({ served: true, method: req.method, url: req.url, raw, body, turn });
      let specs;
      try {
        specs = respond(body, turn);
      } catch (error) {
        onError({ turn, stage: 'responder', message: error.message });
        specs = [{ type: 'message', text: `mock responder error: ${error.message}` }];
      }
      if (!Array.isArray(specs) || specs.length === 0) {
        specs = [{ type: 'message', text: `probe turn ${turn}: nothing more to do, ending the turn.` }];
      }
      let items;
      try {
        items = specs.map((spec, index) => outputItem(spec, index, turn));
      } catch (error) {
        onError({ turn, stage: 'spec', message: error.message });
        items = [outputItem({ type: 'message', text: `mock spec error: ${error.message}` }, 0, turn)];
      }
      streamResponse(res, items, turn);
    });
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      resolve({
        port: server.address().port,
        close: () => new Promise((done) => server.close(() => done())),
      });
    });
  });
}

module.exports = { startMockModel };
