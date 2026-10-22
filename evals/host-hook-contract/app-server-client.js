'use strict';

const { spawn } = require('node:child_process');

class AppServerClient {
  constructor({ codex, env, cwd, onServerRequest }) {
    this.child = spawn(codex, ['app-server'], { env, cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    this.nextId = 1;
    this.pending = new Map();
    this.notifications = [];
    this.waiters = [];
    this.stderr = '';
    this.closed = false;
    this.failure = null;
    this.onServerRequest = onServerRequest || (() => ({}));
    let buffer = '';
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', (chunk) => {
      buffer += chunk;
      let index;
      while ((index = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (line) this.handle(line);
      }
    });
    this.child.stderr.setEncoding('utf8');
    this.child.stderr.on('data', (chunk) => {
      this.stderr += chunk;
    });
    this.child.on('error', (error) => this.shutdown(`app-server failed: ${error.message}`));
    this.child.stdin.on('error', (error) => this.shutdown(`app-server input failed: ${error.message}`));
    this.child.on('exit', () => this.shutdown('app-server exited'));
  }

  shutdown(reason) {
    if (this.closed) return;
    this.closed = true;
    this.failure = reason;
    for (const { reject } of this.pending.values()) reject(new Error(reason));
    this.pending.clear();
    this.flushWaiters();
  }

  handle(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.id !== undefined && message.method) {
      Promise.resolve()
        .then(() => this.onServerRequest(message.method, message.params || {}, message))
        .then((result) => this.send({ id: message.id, result: result === undefined ? {} : result }))
        .catch((error) => this.send({ id: message.id, error: { code: -32000, message: String(error.message || error) } }));
      this.flushWaiters();
      return;
    }
    if (message.id !== undefined) {
      const entry = this.pending.get(message.id);
      if (!entry) return;
      this.pending.delete(message.id);
      if (message.error) entry.reject(Object.assign(new Error(message.error.message || 'rpc error'), { rpc: message.error }));
      else entry.resolve(message.result);
      return;
    }
    if (message.method) {
      this.notifications.push(message);
      this.flushWaiters();
    }
  }

  send(message) {
    if (this.closed) return;
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params, timeoutMs = 60000) {
    if (this.closed) return Promise.reject(new Error(`${this.failure}: ${method}`));
    const id = this.nextId;
    this.nextId += 1;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`app-server request timed out: ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });
      this.send({ id, method, params });
    });
  }

  notify(method, params) {
    this.send(params === undefined ? { method } : { method, params });
  }

  flushWaiters() {
    for (const waiter of [...this.waiters]) {
      const found = waiter.predicate();
      if (found || this.closed) {
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        clearTimeout(waiter.timer);
        if (found) waiter.resolve(found);
        else waiter.reject(new Error(`app-server closed while waiting for ${waiter.label}`));
      }
    }
  }

  waitFor(label, predicate, timeoutMs = 60000) {
    const found = predicate();
    if (found) return Promise.resolve(found);
    if (this.closed) return Promise.reject(new Error(`app-server closed while waiting for ${label}`));
    return new Promise((resolve, reject) => {
      const waiter = { label, predicate, resolve, reject };
      waiter.timer = setTimeout(() => {
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        reject(new Error(`timed out waiting for ${label}`));
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  async initialize() {
    const result = await this.request('initialize', {
      clientInfo: { name: 'zensu-hookprobe', title: 'Zensu host hook contract probe', version: '0.0.1' },
      capabilities: { experimentalApi: true },
    });
    this.notify('initialized');
    return result;
  }

  async close() {
    if (this.closed) return;
    this.child.stdin.end();
    await new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.child.kill('SIGKILL');
        resolve();
      }, 5000);
      this.child.once('exit', () => {
        clearTimeout(timer);
        resolve();
      });
      this.child.kill('SIGTERM');
    });
  }
}

module.exports = { AppServerClient };
