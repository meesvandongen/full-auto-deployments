import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 2,
  duration: '12s',
  thresholds: {
    checks: ['rate>0.99'],
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
};

export default function () {
  const response = http.get(`${__ENV.TARGET_URL}/api/double?value=21`);
  check(response, {
    'correct doubled value': (r) => r.status === 200 && r.json('result') === 42,
  });
  sleep(0.2);
}
