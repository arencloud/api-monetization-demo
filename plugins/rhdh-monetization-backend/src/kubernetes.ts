import fs from 'fs';
import https from 'https';

const serviceAccountPath = '/var/run/secrets/kubernetes.io/serviceaccount';

export interface KubernetesResourceList<T = unknown> {
  apiVersion?: string;
  kind?: string;
  metadata?: Record<string, unknown>;
  items: T[];
}

export class KubernetesApiError extends Error {
  constructor(
    readonly statusCode: number,
    readonly method: string,
    readonly path: string,
    message: string,
  ) {
    super(`Kubernetes API ${method} ${path} returned HTTP ${statusCode}: ${message}`);
  }
}

export async function kubernetesRequest<T = unknown>(
  method: string,
  path: string,
  body?: unknown,
): Promise<T> {
  const host = process.env.KUBERNETES_SERVICE_HOST;
  const port = process.env.KUBERNETES_SERVICE_PORT_HTTPS || process.env.KUBERNETES_SERVICE_PORT || '443';
  if (!host) {
    throw new Error('KUBERNETES_SERVICE_HOST is not configured');
  }
  const token = fs.readFileSync(`${serviceAccountPath}/token`, 'utf8').trim();
  const ca = fs.readFileSync(`${serviceAccountPath}/ca.crt`);
  const encoded = body === undefined ? undefined : Buffer.from(JSON.stringify(body));

  return new Promise((resolve, reject) => {
    const request = https.request(
      {
        host,
        port: Number(port),
        path,
        method,
        ca,
        headers: {
          Accept: 'application/json',
          Authorization: `Bearer ${token}`,
          ...(encoded ? {
            'Content-Type': method === 'PATCH'
              ? 'application/merge-patch+json'
              : 'application/json',
            'Content-Length': String(encoded.length),
          } : {}),
        },
        timeout: 10_000,
      },
      response => {
        const chunks: Buffer[] = [];
        response.on('data', chunk => chunks.push(Buffer.from(chunk)));
        response.on('end', () => {
          const body = Buffer.concat(chunks).toString('utf8');
          if (!response.statusCode || response.statusCode < 200 || response.statusCode >= 300) {
            reject(new KubernetesApiError(
              response.statusCode || 0,
              method,
              path,
              body.slice(0, 1024),
            ));
            return;
          }
          if (!body) {
            resolve(undefined as T);
            return;
          }
          try {
            resolve(JSON.parse(body) as T);
          } catch {
            reject(new Error('Kubernetes returned invalid JSON for TokenRateLimitPolicy list'));
          }
        });
      },
    );
    request.on('timeout', () => request.destroy(new Error('Kubernetes request timed out')));
    request.on('error', reject);
    if (encoded) request.write(encoded);
    request.end();
  });
}

export async function listTokenRateLimitPolicies<T = unknown>(): Promise<KubernetesResourceList<T>> {
  return kubernetesRequest<KubernetesResourceList<T>>(
    'GET',
    '/apis/kuadrant.io/v1alpha1/tokenratelimitpolicies',
  );
}
