'use strict';

const assert = require('node:assert/strict');
const bcrypt = require('bcryptjs');
const { after, before, test } = require('node:test');
const { createServer } = require('node:http');
const { createApp } = require('./server');

let server;
let baseUrl;
const calls = [];
let shouldFailHealth = false;
let shouldRejectRegistration = false;
const sessions = new Map();
const users = new Map();

before(async () => {
  const knownPassword = 'TestPassword2026!!';
  const knownUser = {
    id: 1,
    name: 'Ada Lovelace',
    email: 'ada@example.test',
    password_hash: await bcrypt.hash(knownPassword, 4),
    created_at: '2026-01-01T00:00:00.000Z',
  };
  users.set(knownUser.email, knownUser);
  const pool = {
    async query(sql) {
      calls.push({ method: 'query', sql });
      if (shouldFailHealth) {
        throw new Error('internal database error');
      }
      return [[{ ok: 1 }]];
    },
    async execute(sql, values) {
      calls.push({ method: 'execute', sql, values });
      if (sql.startsWith('INSERT INTO users')) {
        if (shouldRejectRegistration) {
          const error = new Error('Duplicate entry');
          error.code = 'ER_DUP_ENTRY';
          throw error;
        }
        users.set(values[1], {
          id: 2,
          name: values[0],
          email: values[1],
          password_hash: values[2],
          created_at: '2026-01-01T00:00:00.000Z',
        });
        return [{ insertId: 2 }];
      }
      if (sql.startsWith('SELECT id, name, email, password_hash FROM users')) {
        const user = users.get(values[0]);
        return [user ? [{ ...user }] : []];
      }
      if (sql.startsWith('INSERT INTO auth_sessions')) {
        sessions.set(values[0], values[1]);
        return [{ insertId: 1 }];
      }
      if (sql.includes('FROM auth_sessions s')) {
        const userId = sessions.get(values[0]);
        const user = [...users.values()].find((entry) => entry.id === userId);
        return [user ? [{ id: user.id, name: user.name, email: user.email }] : []];
      }
      if (sql.startsWith('DELETE FROM auth_sessions')) {
        sessions.delete(values[0]);
        return [{ affectedRows: 1 }];
      }
      if (sql.startsWith('SELECT id, name, email, created_at FROM users')) {
        return [[...users.values()].map(({ id, name, email, created_at }) => ({
          id,
          name,
          email,
          created_at,
        }))];
      }
      throw new Error(`Unexpected test query: ${sql}`);
    },
  };
  server = createServer(createApp(pool));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
});

test('home page is served', async () => {
  const response = await fetch(baseUrl);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Three-tier application/);
});

test('registration page is served', async () => {
  const response = await fetch(`${baseUrl}/register`);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Create an account/);
});

test('login form is served', async () => {
  const response = await fetch(`${baseUrl}/login`);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Log in/);
});

test('registration inserts a normalized email and a password hash', async () => {
  const response = await fetch(`${baseUrl}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      name: '  Ada Lovelace ',
      email: ' New.User@example.test ',
      password: 'correct horse battery staple',
    }),
  });

  assert.equal(response.status, 201);
  assert.deepEqual(await response.json(), { message: 'Registration successful' });
  const insertion = calls.findLast((entry) => entry.sql.startsWith('INSERT INTO users'));
  assert.match(insertion.sql, /VALUES \(\?, \?, \?\)/);
  assert.equal(insertion.values[0], 'Ada Lovelace');
  assert.equal(insertion.values[1], 'new.user@example.test');
  assert.match(insertion.values[2], /^\$2[aby]\$/);
  assert.notEqual(insertion.values[2], 'correct horse battery staple');
  users.delete('new.user@example.test');
});

test('registration validates required fields before accessing the database', async () => {
  const previousCallCount = calls.length;
  const response = await fetch(`${baseUrl}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ name: 'Ada', email: 'ada@example.test', password: 'short' }),
  });

  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    error: 'Password must be at least 12 characters and at most 72 UTF-8 bytes',
  });
  assert.equal(calls.length, previousCallCount);
});

test('registration reports duplicate emails without leaking database errors', async () => {
  shouldRejectRegistration = true;
  const response = await fetch(`${baseUrl}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      name: 'Ada',
      email: 'ada@example.test',
      password: 'correct horse battery staple',
    }),
  });
  shouldRejectRegistration = false;

  assert.equal(response.status, 409);
  assert.deepEqual(await response.json(), {
    error: 'An account with this email already exists',
  });
});

test('login creates an HttpOnly, SameSite session cookie', async () => {
  const response = await fetch(`${baseUrl}/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: ' ADA@example.test ',
      password: 'TestPassword2026!!',
    }),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { message: 'Login successful' });
  const cookie = response.headers.get('set-cookie');
  assert.match(cookie, /app_session=[A-Za-z0-9_-]{43}/);
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /SameSite=Lax/);
  assert.doesNotMatch(cookie, /Secure/);
  assert.equal(sessions.size, 1);
  sessions.clear();
});

test('login rejects an incorrect password without revealing account state', async () => {
  const response = await fetch(`${baseUrl}/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: 'ada@example.test',
      password: 'incorrect password',
    }),
  });

  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: 'Invalid email or password' });
});

test('dashboard requires a valid login and logout revokes the session', async () => {
  const anonymous = await fetch(`${baseUrl}/dashboard`, { redirect: 'manual' });
  assert.equal(anonymous.status, 303);
  assert.equal(anonymous.headers.get('location'), '/login');

  const loginResponse = await fetch(`${baseUrl}/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: 'ada@example.test',
      password: 'TestPassword2026!!',
    }),
  });
  const cookie = loginResponse.headers.get('set-cookie').split(';')[0];

  const dashboard = await fetch(`${baseUrl}/dashboard`, {
    headers: { cookie },
    redirect: 'manual',
  });
  assert.equal(dashboard.status, 200);
  assert.match(await dashboard.text(), /Your dashboard/);

  const account = await fetch(`${baseUrl}/api/me`, { headers: { cookie } });
  assert.equal(account.status, 200);
  assert.deepEqual((await account.json()).user, {
    id: 1,
    name: 'Ada Lovelace',
    email: 'ada@example.test',
  });

  const logout = await fetch(`${baseUrl}/logout`, {
    method: 'POST',
    headers: { cookie },
  });
  assert.equal(logout.status, 200);
  assert.match(logout.headers.get('set-cookie'), /Max-Age=0/);
  assert.equal(sessions.size, 0);

  const afterLogout = await fetch(`${baseUrl}/dashboard`, {
    headers: { cookie },
    redirect: 'manual',
  });
  assert.equal(afterLogout.status, 303);
});

test('health endpoint reports database connectivity', async () => {
  const response = await fetch(`${baseUrl}/health`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    status: 'ok',
    application: 'connected',
    database: 'connected',
  });
});

test('health endpoint gives a safe degraded response when the database is down', async () => {
  shouldFailHealth = true;
  const response = await fetch(`${baseUrl}/health`);
  shouldFailHealth = false;
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    status: 'degraded',
    application: 'connected',
    database: 'unavailable',
  });
});

test('users endpoint parameterizes its row limit', async () => {
  const response = await fetch(`${baseUrl}/users?limit=4`);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).users.length, 1);
  const call = calls.findLast((entry) => entry.method === 'execute');
  assert.match(call.sql, /LIMIT \?/);
  assert.deepEqual(call.values, [4]);
});

test('users endpoint rejects invalid limits', async () => {
  const response = await fetch(`${baseUrl}/users?limit=1%20OR%201=1`);
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    error: 'limit must be an integer from 1 to 100',
  });
});
