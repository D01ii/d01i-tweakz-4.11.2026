import express from 'express';
import helmet from 'helmet';
import cookieParser from 'cookie-parser';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { config, safePublicConfig } from './config/index.js';
import { ipHashMiddleware, blockCheckMiddleware, errorHandler, notFound } from './middleware/common.js';
import licenseV1 from './routes/v1/license.js';
import adminAuth from './routes/admin/auth.js';
import adminLicenses from './routes/admin/licenses.js';
import adminOps from './routes/admin/ops.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export function createApp() {
  const app = express();

  app.disable('x-powered-by');
  app.set('trust proxy', config.isProduction ? 1 : false);

  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          scriptSrc: ["'self'"],
          styleSrc: ["'self'", "'unsafe-inline'"],
          imgSrc: ["'self'", 'data:'],
          connectSrc: ["'self'"],
          frameAncestors: ["'none'"],
        },
      },
      crossOriginEmbedderPolicy: false,
      frameguard: { action: 'deny' },
    })
  );
  app.use(express.json({ limit: '64kb' }));
  // R7: odpowiedzi API nigdy nie mogą być keszowane (sekrety MFA, tokeny, dane licencji).
  app.use('/api', (req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  app.use(cookieParser());
  app.use(ipHashMiddleware);
  app.use(blockCheckMiddleware);

  app.get('/api/v1/config', (req, res) => res.json({ ok: true, config: safePublicConfig() }));

  app.use('/api/v1/license', licenseV1);
  app.use('/api/v1/admin', adminAuth);
  app.use('/api/v1/admin/licenses', adminLicenses);
  app.use('/api/v1/admin/ops', adminOps);

  // Panel administracyjny (statyczny SPA)
  const publicDir = path.join(__dirname, 'public');
  if (fs.existsSync(publicDir)) {
    app.use(express.static(publicDir, { maxAge: 0 }));
    app.get('/admin', (req, res) => res.redirect('/admin/'));
    app.get('/admin/*', (req, res) => res.sendFile(path.join(publicDir, 'admin', 'index.html')));
  }
  app.get('/', (req, res) => res.json({ ok: true, product: 'D01i Tweakz Backend', version: '1.0.0', adminPanel: '/admin' }));

  app.use('/api', notFound);
  app.use(errorHandler);
  return app;
}
