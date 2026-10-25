'use strict';

const crypto = require('node:crypto');
const path = require('node:path');
const express = require('express');
const mysql = require('mysql2/promise');
const bcrypt = require('bcryptjs');

const SESSION_COOKIE = 'app_session';
const SESSION_TTL_SECONDS = 8 * 60 * 60;

function hashSessionToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

function sessionCookie(token, maxAge) {
  const secure = process.env.NODE_ENV === 'production' ? '; Secure' : '';
  return `${SESSION_COOKIE}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${secure}`;
}

function getSessionToken(request) {
  const cookieHeader = request.headers.cookie || '';
  const cookie = cookieHeader
    .split(';')
    .map((part) => part.trim())
    .find((part) => part.startsWith(`${SESSION_COOKIE}=`));
  if (!cookie) {
    return null;
  }

  const token = cookie.slice(SESSION_COOKIE.length + 1);
  return /^[A-Za-z0-9_-]{43}$/.test(token) ? token : null;
}

function createApp(pool) {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '10kb' }));
  app.use(express.static(path.join(__dirname, 'public')));

  app.get('/register', (_request, response) => {
    response.sendFile(path.join(__dirname, 'public', 'register.html'));
  });

  app.get('/login', (_request, response) => {
    response.sendFile(path.join(__dirname, 'public', 'login.html'));
  });

  app.post('/login', async (request, response) => {
    const email = typeof request.body?.email === 'string'
      ? request.body.email.trim().toLowerCase()
      : '';
    const password = typeof request.body?.password === 'string' ? request.body.password : '';

    if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
      || password.length < 1 || Buffer.byteLength(password, 'utf8') > 72) {
      response.status(400).json({ error: 'Enter a valid email and password' });
      return;
    }

    try {
      const [users] = await pool.execute(
        'SELECT id, name, email, password_hash FROM users WHERE email = ? LIMIT 1',
        [email],
      );
      const user = users[0];
      const passwordMatches = user?.password_hash
        ? await bcrypt.compare(password, user.password_hash)
        : false;

      if (!passwordMatches) {
        response.status(401).json({ error: 'Invalid email or password' });
        return;
      }

      const token = crypto.randomBytes(32).toString('base64url');
      await pool.execute(
        'INSERT INTO auth_sessions (token_hash, user_id, expires_at) VALUES (?, ?, DATE_ADD(UTC_TIMESTAMP(), INTERVAL 8 HOUR))',
        [hashSessionToken(token), user.id],
      );

      response.setHeader('Set-Cookie', sessionCookie(token, SESSION_TTL_SECONDS));
      response.json({ message: 'Login successful' });
    } catch {
      response.status(503).json({ error: 'Login is temporarily unavailable' });
    }
  });

  app.post('/logout', async (request, response) => {
    const token = getSessionToken(request);
    if (token) {
      try {
        await pool.execute('DELETE FROM auth_sessions WHERE token_hash = ?', [hashSessionToken(token)]);
      } catch {
        response.status(503).json({ error: 'Logout is temporarily unavailable' });
        return;
      }
    }

    response.setHeader('Set-Cookie', sessionCookie('', 0));
    response.json({ message: 'Logged out' });
  });

  async function findSessionUser(request) {
    const token = getSessionToken(request);
    if (!token) {
      return null;
    }

    const [users] = await pool.execute(
      `SELECT u.id, u.name, u.email
       FROM auth_sessions s
       JOIN users u ON u.id = s.user_id
       WHERE s.token_hash = ? AND s.expires_at > UTC_TIMESTAMP()
       LIMIT 1`,
      [hashSessionToken(token)],
    );
    return users[0] || null;
  }

  app.get('/api/me', async (request, response) => {
    try {
      const user = await findSessionUser(request);
      if (!user) {
        response.status(401).json({ error: 'Authentication required' });
        return;
      }
      response.json({ user });
    } catch {
      response.status(503).json({ error: 'Account information is temporarily unavailable' });
    }
  });

  app.get('/dashboard', async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    try {
      const user = await findSessionUser(request);
      if (!user) {
        response.redirect(303, '/login');
        return;
      }
      response.sendFile(path.join(__dirname, 'private', 'dashboard.html'));
    } catch {
      response.status(503).send('Dashboard is temporarily unavailable.');
    }
  });

  app.post('/register', async (request, response) => {
    const name = typeof request.body?.name === 'string' ? request.body.name.trim() : '';
    const email = typeof request.body?.email === 'string'
      ? request.body.email.trim().toLowerCase()
      : '';
    const password = typeof request.body?.password === 'string' ? request.body.password : '';

    if (name.length < 1 || name.length > 120) {
      response.status(400).json({ error: 'Name must be between 1 and 120 characters' });
      return;
    }
    if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      response.status(400).json({ error: 'Enter a valid email address' });
      return;
    }
    if (password.length < 12 || Buffer.byteLength(password, 'utf8') > 72) {
      response.status(400).json({ error: 'Password must be at least 12 characters and at most 72 UTF-8 bytes' });
      return;
    }

    try {
      const passwordHash = await bcrypt.hash(password, 12);
      await pool.execute(
        'INSERT INTO users (name, email, password_hash) VALUES (?, ?, ?)',
        [name, email, passwordHash],
      );
      response.status(201).json({ message: 'Registration successful' });
    } catch (error) {
      if (error.code === 'ER_DUP_ENTRY') {
        response.status(409).json({ error: 'An account with this email already exists' });
        return;
      }
      response.status(503).json({ error: 'Registration is temporarily unavailable' });
    }
  });

  app.get('/health', async (_request, response) => {
    try {
      await pool.query('SELECT 1');
      response.status(200).json({
        status: 'ok',
        application: 'connected',
        database: 'connected',
      });
    } catch {
      response.status(503).json({
        status: 'degraded',
        application: 'connected',
        database: 'unavailable',
      });
    }
  });

  app.get('/users', async (request, response) => {
    const limit = request.query.limit === undefined ? 100 : Number(request.query.limit);
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
      response.status(400).json({ error: 'limit must be an integer from 1 to 100' });
      return;
    }

    try {
      const [users] = await pool.execute(
        'SELECT id, name, email, created_at FROM users ORDER BY id LIMIT ?',
        [limit],
      );
      response.json({ users });
    } catch {
      response.status(503).json({ error: 'User data is temporarily unavailable' });
    }
  });

  app.use((_request, response) => {
    response.status(404).json({ error: 'Not found' });
  });

  app.use((error, _request, response, _next) => {
    if (error instanceof SyntaxError && error.status === 400 && 'body' in error) {
      response.status(400).json({ error: 'Request body must contain valid JSON' });
      return;
    }
    console.error('Unhandled request error.');
    response.status(500).json({ error: 'Internal server error' });
  });

  return app;
}

function start() {
  const port = Number(process.env.PORT || 3000);
  const host = process.env.HOST || '127.0.0.1';
  const required = ['DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASSWORD'];
  const missing = required.filter((key) => !process.env[key]);
  if (missing.length > 0) {
    console.error('Required database configuration is missing.');
    process.exitCode = 1;
    return;
  }

  const pool = mysql.createPool({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT || 3306),
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0,
    connectTimeout: 5000,
  });

  const server = createApp(pool).listen(port, host, () => {
    console.log(`Application listening on ${host}:${port}`);
  });

  const shutdown = () => {
    server.close(() => {
      pool.end().finally(() => process.exit(0));
    });
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

if (require.main === module) {
  start();
}

module.exports = { createApp };
