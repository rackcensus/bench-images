import http from 'k6/http';
import { check } from 'k6';

const STEPS = ['topic', 'topic_json', 'home', 'categories', 'user_activity'];
const CYCLE = ['topic', 'home', 'topic_json', 'topic', 'categories', 'topic', 'topic_json', 'home', 'user_activity', 'topic'];
const SCENARIOS = ['signed_in', 'anonymous'];
const BROWSER = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

const BASE_URL = (__ENV.RC_BASE_URL || 'http://discourse').replace(/\/+$/, '');
const SCENARIO = __ENV.RC_SCENARIO;
const VUS = parseInt(__ENV.RC_VUS, 10);
const DURATION = __ENV.RC_DURATION;
const SUMMARY_PATH = __ENV.RC_SUMMARY_PATH;

if (SCENARIOS.indexOf(SCENARIO) === -1) {
  throw new Error(`RC_SCENARIO must be one of ${SCENARIOS.join(', ')}, got ${SCENARIO}`);
}
if (!(VUS > 0) || String(VUS) !== String(__ENV.RC_VUS).trim()) {
  throw new Error(`RC_VUS must be a positive integer, got ${__ENV.RC_VUS}`);
}
if (!/^[0-9]+(ms|s|m|h)$/.test(DURATION || '')) {
  throw new Error(`RC_DURATION must look like 60s, got ${DURATION}`);
}
if (!SUMMARY_PATH) {
  throw new Error('RC_SUMMARY_PATH is required');
}

const DATA = loadData();

function loadData() {
  let raw = __ENV.RC_DISCOURSE_DATA;
  if (!raw && __ENV.RC_DISCOURSE_DATA_FILE) {
    raw = open(__ENV.RC_DISCOURSE_DATA_FILE);
  }
  if (!raw) {
    throw new Error('RC_DISCOURSE_DATA or RC_DISCOURSE_DATA_FILE is required');
  }
  const data = JSON.parse(raw);
  for (const key of ['topic_path', 'user_activity_path']) {
    if (typeof data[key] !== 'string' || data[key].charAt(0) !== '/') {
      throw new Error(`${key} must be a site-relative path starting with /, got ${data[key]}`);
    }
  }
  if (!Array.isArray(data.usernames) || data.usernames.length === 0 || !data.usernames.every((name) => typeof name === 'string' && name.length > 0)) {
    throw new Error('usernames must be a non-empty array of strings');
  }
  if (typeof data.password !== 'string' || data.password.length === 0) {
    throw new Error('password is required');
  }
  return {
    usernames: data.usernames,
    password: data.password,
    paths: {
      topic: data.topic_path,
      topic_json: `${data.topic_path}.json`,
      home: '/',
      categories: '/categories',
      user_activity: data.user_activity_path,
    },
  };
}

function buildThresholds() {
  const thresholds = {};
  for (const step of STEPS) {
    thresholds[`http_req_duration{step:${step},expected_response:true}`] = ['max>=0'];
    thresholds[`http_reqs{step:${step}}`] = ['count>=0'];
    thresholds[`http_req_failed{step:${step}}`] = ['rate>=0'];
  }
  return thresholds;
}

export const options = {
  scenarios: {
    [SCENARIO]: {
      executor: 'constant-vus',
      exec: SCENARIO,
      vus: VUS,
      duration: DURATION,
      gracefulStop: '10s',
    },
  },
  thresholds: buildThresholds(),
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
  discardResponseBodies: true,
  noCookiesReset: true,
  setupTimeout: '120s',
  userAgent: BROWSER,
};

http.setResponseCallback(http.expectedStatuses(200));

function signIn(username) {
  const headers = { 'X-Requested-With': 'XMLHttpRequest', Accept: 'application/json' };
  const csrf = http.get(`${BASE_URL}/session/csrf`, { headers, responseType: 'text', redirects: 0, tags: { name: 'sign_in' } });
  if (csrf.status !== 200) {
    throw new Error(`csrf token request returned status ${csrf.status}`);
  }
  const session = http.post(`${BASE_URL}/session`, { login: username, password: DATA.password }, {
    headers: Object.assign({ 'X-CSRF-Token': csrf.json('csrf') }, headers),
    responseType: 'text',
    redirects: 0,
    tags: { name: 'sign_in' },
  });
  if (session.status !== 200 || session.json('error') || session.json('user.username') !== username) {
    throw new Error(`signing in as ${username} returned status ${session.status}: ${String(session.body).slice(0, 200)}`);
  }
}

function request(step, signedIn) {
  const html = step !== 'topic_json';
  const res = http.get(`${BASE_URL}${DATA.paths[step]}`, {
    headers: { Accept: html ? 'text/html' : 'application/json' },
    responseType: signedIn && html ? 'text' : 'none',
    redirects: 0,
    tags: { step, name: step },
  });
  const checks = {};
  checks[`${step} status is 200`] = (r) => r.status === 200;
  if (signedIn && html) {
    checks[`${step} is signed in`] = (r) => r.status !== 200 || String(r.body).indexOf('currentUser') !== -1;
  }
  check(res, checks, { step });
  return res;
}

function nextStep() {
  return CYCLE[(__ITER + __VU) % CYCLE.length];
}

export function setup() {
  const topic = http.get(`${BASE_URL}${DATA.paths.topic}`, { headers: { Accept: 'text/html' }, redirects: 0, tags: { name: 'setup_topic' } });
  if (topic.status !== 200) {
    throw new Error(`the seeded topic ${DATA.paths.topic} returned status ${topic.status}`);
  }
  if (SCENARIO === 'signed_in') {
    signIn(DATA.usernames[0]);
  }
  return {};
}

let signedIn = false;

export function signed_in() {
  if (!signedIn) {
    signIn(DATA.usernames[(__VU - 1) % DATA.usernames.length]);
    signedIn = true;
  }
  request(nextStep(), true);
}

export function anonymous() {
  request(nextStep(), false);
}

export function handleSummary(data) {
  const out = {};
  out[SUMMARY_PATH] = JSON.stringify(data);
  out.stdout = `k6 ${SCENARIO} with ${VUS} vus for ${DURATION} finished, summary written to ${SUMMARY_PATH}\n`;
  return out;
}
