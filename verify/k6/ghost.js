import http from 'k6/http';
import { check, sleep } from 'k6';

const SCENARIOS = {
  reader: {
    steps: ['home', 'post', 'tag', 'author', 'rss'],
    cycle: ['post', 'home', 'post', 'tag', 'post', 'home', 'post', 'author', 'post', 'rss'],
  },
  staff: {
    steps: ['admin_posts', 'admin_post', 'admin_save', 'admin_members'],
    cycle: ['admin_posts', 'admin_post', 'admin_save', 'admin_post', 'admin_save', 'admin_members', 'admin_post', 'admin_save'],
  },
};
const BROWSER = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

const BASE_URL = (__ENV.RC_BASE_URL || 'http://ghost:2368').replace(/\/+$/, '');
const ORIGIN = __ENV.RC_ORIGIN || 'http://ghost';
const SCENARIO = __ENV.RC_SCENARIO;
const VUS = parseInt(__ENV.RC_VUS, 10);
const DURATION = __ENV.RC_DURATION;
const SUMMARY_PATH = __ENV.RC_SUMMARY_PATH;

if (!SCENARIOS[SCENARIO]) {
  throw new Error(`RC_SCENARIO must be one of ${Object.keys(SCENARIOS).join(', ')}, got ${SCENARIO}`);
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
const STEPS = SCENARIOS[SCENARIO].steps;
const CYCLE = SCENARIOS[SCENARIO].cycle;

function sitePaths(data, key) {
  const value = data[key];
  if (!Array.isArray(value) || value.length === 0 || !value.every((path) => typeof path === 'string' && path.charAt(0) === '/')) {
    throw new Error(`${key} must be a non-empty array of site-relative paths`);
  }
  return value;
}

function loadData() {
  let raw = __ENV.RC_GHOST_DATA;
  if (!raw && __ENV.RC_GHOST_DATA_FILE) {
    raw = open(__ENV.RC_GHOST_DATA_FILE);
  }
  if (!raw) {
    throw new Error('RC_GHOST_DATA or RC_GHOST_DATA_FILE is required');
  }
  const data = JSON.parse(raw);
  if (typeof data.author_path !== 'string' || data.author_path.charAt(0) !== '/') {
    throw new Error(`author_path must be a site-relative path starting with /, got ${data.author_path}`);
  }
  if (!Array.isArray(data.draft_post_ids) || data.draft_post_ids.length === 0) {
    throw new Error('draft_post_ids must be a non-empty array');
  }
  if (typeof data.staff_email !== 'string' || typeof data.password !== 'string' || !data.password) {
    throw new Error('staff_email and password are required');
  }
  return {
    postPaths: sitePaths(data, 'post_paths'),
    tagPaths: sitePaths(data, 'tag_paths'),
    authorPath: data.author_path,
    draftIds: data.draft_post_ids,
    email: data.staff_email,
    password: data.password,
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

function admin(method, path, body, step) {
  const params = {
    headers: { Origin: ORIGIN, Accept: 'application/json', 'Content-Type': 'application/json' },
    responseType: 'text',
    redirects: 0,
    tags: step ? { step, name: step } : { name: 'sign_in' },
  };
  if (method === 'POST') {
    params.responseCallback = http.expectedStatuses(201);
  }
  return http.request(method, `${BASE_URL}/ghost/api/admin${path}`, body === null ? null : JSON.stringify(body), params);
}

function signIn() {
  let session = null;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    session = admin('POST', '/session/', { username: DATA.email, password: DATA.password }, null);
    if (session.status !== 500) break;
    sleep(0.2 + Math.random());
  }
  if (session.status !== 201) {
    throw new Error(`signing in as ${DATA.email} returned status ${session.status}: ${String(session.body).slice(0, 200)}`);
  }
}

function pathFor(step) {
  if (step === 'post') return DATA.postPaths[Math.floor(Math.random() * DATA.postPaths.length)];
  if (step === 'tag') return DATA.tagPaths[Math.floor(Math.random() * DATA.tagPaths.length)];
  if (step === 'author') return DATA.authorPath;
  if (step === 'rss') return '/rss/';
  return '/';
}

function read(step) {
  const res = http.get(`${BASE_URL}${pathFor(step)}`, {
    headers: { Accept: step === 'rss' ? 'application/rss+xml' : 'text/html' },
    responseType: 'none',
    redirects: 0,
    tags: { step, name: step },
  });
  check(res, { [`${step} status is 200`]: (r) => r.status === 200 }, { step });
}

function draftId() {
  return DATA.draftIds[(__VU - 1) % DATA.draftIds.length];
}

let draft = null;

function work(step) {
  let res;
  if (step === 'admin_posts') {
    res = admin('GET', '/posts/?formats=mobiledoc%2Clexical&limit=20&page=1&order=updated_at%20desc', null, step);
  } else if (step === 'admin_members') {
    res = admin('GET', '/members/?limit=50&order=created_at%20desc&include=labels', null, step);
  } else if (step === 'admin_post') {
    res = admin('GET', `/posts/${draftId()}/?formats=mobiledoc%2Clexical&include=tags%2Cauthors%2Cauthors.roles%2Cemail%2Ctiers%2Cnewsletter`, null, step);
    if (res.status === 200) {
      draft = res.json('posts.0');
    }
  } else {
    if (!draft) {
      const fresh = admin('GET', `/posts/${draftId()}/?formats=lexical`, null, null);
      draft = fresh.status === 200 ? fresh.json('posts.0') : null;
    }
    const body = draft ? { posts: [{ title: `${draft.title.replace(/ \(edit [0-9]+\)$/, '')} (edit ${__ITER})`, updated_at: draft.updated_at }] } : { posts: [{}] };
    res = admin('PUT', `/posts/${draftId()}/?formats=lexical`, body, step);
    draft = res.status === 200 ? res.json('posts.0') : null;
  }
  const checks = { [`${step} status is 200`]: (r) => r.status === 200 };
  check(res, checks, { step });
}

function nextStep() {
  return CYCLE[(__ITER + __VU) % CYCLE.length];
}

export function setup() {
  const post = http.get(`${BASE_URL}${DATA.postPaths[0]}`, { headers: { Accept: 'text/html' }, redirects: 0, tags: { name: 'setup_post' } });
  if (post.status !== 200) {
    throw new Error(`the seeded post ${DATA.postPaths[0]} returned status ${post.status}`);
  }
  if (SCENARIO === 'staff') {
    signIn();
  }
  return {};
}

let signedIn = false;

export function reader() {
  read(nextStep());
}

export function staff() {
  if (!signedIn) {
    signIn();
    signedIn = true;
  }
  work(nextStep());
}

export function handleSummary(data) {
  const out = {};
  out[SUMMARY_PATH] = JSON.stringify(data);
  out.stdout = `k6 ${SCENARIO} with ${VUS} vus for ${DURATION} finished, summary written to ${SUMMARY_PATH}\n`;
  return out;
}
