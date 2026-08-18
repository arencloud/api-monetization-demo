import fs from 'fs';
import https from 'https';

const serviceAccountPath = '/var/run/secrets/kubernetes.io/serviceaccount';

export interface KubernetesResourceList<T = unknown> {
  apiVersion?: string;
  kind?: string;
  metadata?: Record<string, unknown>;
  items: T[];
}

export async function listTokenRateLimitPolicies<T = unknown>(): Promise<KubernetesResourceList<T>> {
  const host = process.env.KUBERNETES_SERVICE_HOST;
  const port = process.env.KUBERNETES_SERVICE_PORT_HTTPS || process.env.KUBERNETES_SERVICE_PORT || '443';
  if (!host) {
    throw new Error('KUBERNETES_SERVICE_HOST is not configured');
  }
  const token = fs.readFileSync(`${serviceAccountPath}/token`, 'utf8').trim();
  const ca = fs.readFileSync(`${serviceAccountPath}/ca.crt`);
  const path = '/apis/kuadrant.io/v1alpha1/tokenratelimitpolicies';

  return new Promise((resolve, reject) => {
    const request = https.request(
      {
        host,
        port: Number(port),
        path,
        method: 'GET',
        ca,
        headers: {
          Accept: 'application/json',
          Authorization: `Bearer ${token}`,
        },
        timeout: 10_000,
      },
      response => {
        const chunks: Buffer[] = [];
        response.on('data', chunk => chunks.push(Buffer.from(chunk)));
        response.on('end', () => {
          const body = Buffer.concat(chunks).toString('utf8');
          if (!response.statusCode || response.statusCode < 200 || response.statusCode >= 300) {
            reject(new Error(`Kubernetes TokenRateLimitPolicy list failed: HTTP ${response.statusCode || 0}`));
            return;
          }
          try {
            resolve(JSON.parse(body) as KubernetesResourceList<T>);
          } catch {
            reject(new Error('Kubernetes returned invalid JSON for TokenRateLimitPolicy list'));
          }
        });
      },
    );
    request.on('timeout', () => request.destroy(new Error('Kubernetes request timed out')));
    request.on('error', reject);
    request.end();
  });
}
