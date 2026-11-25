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
  const response = http.get(`${__ENV.TARGET_URL}/api/greet?name=World`);
  check(response, {
    'correct greeting': (r) => r.status === 200 && r.json('message') === 'hello World',
  });
  sleep(0.2);
}
