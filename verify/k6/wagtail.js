import http from 'k6/http';
import { check } from 'k6';

const SCENARIOS = {
  visitor: {
    steps: ['home', 'blog_index', 'blog_post', 'bread', 'location', 'site_search'],
    cycle: ['blog_post', 'home', 'bread', 'blog_post', 'location', 'bread', 'blog_index', 'blog_post', 'site_search', 'bread'],
  },
  editor: {
    steps: ['admin_dashboard', 'admin_explorer', 'admin_editor', 'admin_images', 'admin_search'],
    cycle: ['admin_dashboard', 'admin_explorer', 'admin_editor', 'admin_explorer', 'admin_editor', 'admin_images', 'admin_editor', 'admin_search'],
  },
};
const BROWSER = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

const BASE_URL = (__ENV.RC_BASE_URL || 'http://wagtail:8000').replace(/\/+$/, '');
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
  let raw = __ENV.RC_WAGTAIL_DATA;
  if (!raw && __ENV.RC_WAGTAIL_DATA_FILE) {
    raw = open(__ENV.RC_WAGTAIL_DATA_FILE);
  }
  if (!raw) {
    throw new Error('RC_WAGTAIL_DATA or RC_WAGTAIL_DATA_FILE is required');
  }
  const data = JSON.parse(raw);
  if (typeof data.blog_index_path !== 'string' || data.blog_index_path.charAt(0) !== '/') {
    throw new Error(`blog_index_path must be a site-relative path starting with /, got ${data.blog_index_path}`);
  }
  if (!Array.isArray(data.search_terms) || data.search_terms.length === 0) {
    throw new Error('search_terms must be a non-empty array');
  }
  if (!Array.isArray(data.edit_page_ids) || data.edit_page_ids.length === 0 || !(data.explorer_page_id > 0)) {
    throw new Error('edit_page_ids and explorer_page_id are required');
  }
  if (typeof data.username !== 'string' || typeof data.password !== 'string' || !data.password) {
    throw new Error('username and password are required');
  }
  return {
    blogIndexPath: data.blog_index_path,
    blogPaths: sitePaths(data, 'blog_paths'),
    breadPaths: sitePaths(data, 'bread_paths'),
    locationPaths: sitePaths(data, 'location_paths'),
    searchTerms: data.search_terms,
    explorerPageId: data.explorer_page_id,
    editPageIds: data.edit_page_ids,
    username: data.username,
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
  noConnectionReuse: true,
  setupTimeout: '120s',
  userAgent: BROWSER,
};

http.setResponseCallback(http.expectedStatuses(200));

function any(list) {
  return list[Math.floor(Math.random() * list.length)];
}

function pathFor(step) {
  if (step === 'blog_index') return DATA.blogIndexPath;
  if (step === 'blog_post') return any(DATA.blogPaths);
  if (step === 'bread') return any(DATA.breadPaths);
  if (step === 'location') return any(DATA.locationPaths);
  if (step === 'site_search') return `/search/?q=${encodeURIComponent(any(DATA.searchTerms))}`;
  if (step === 'admin_dashboard') return '/admin/';
  if (step === 'admin_explorer') return `/admin/pages/${DATA.explorerPageId}/`;
  if (step === 'admin_editor') return `/admin/pages/${DATA.editPageIds[(__VU + __ITER) % DATA.editPageIds.length]}/edit/`;
  if (step === 'admin_images') return '/admin/images/';
  if (step === 'admin_search') return `/admin/pages/search/?q=${encodeURIComponent(any(DATA.searchTerms))}`;
  return '/';
}

function signIn() {
  const form = http.get(`${BASE_URL}/admin/login/`, { responseType: 'text', redirects: 0, tags: { name: 'sign_in' } });
  const token = /name="csrfmiddlewaretoken" value="([^"]+)"/.exec(String(form.body));
  if (form.status !== 200 || !token) {
    throw new Error(`the admin login form returned status ${form.status} without a csrf token`);
  }
  const session = http.post(`${BASE_URL}/admin/login/`, {
    csrfmiddlewaretoken: token[1],
    username: DATA.username,
    password: DATA.password,
    next: '/admin/',
  }, {
    headers: { Referer: `${BASE_URL}/admin/login/` },
    responseType: 'text',
    redirects: 0,
    tags: { name: 'sign_in' },
    responseCallback: http.expectedStatuses(302),
  });
  if (session.status !== 302 || String(session.headers.Location).indexOf('/admin/') === -1) {
    throw new Error(`signing in as ${DATA.username} returned status ${session.status}: ${String(session.body).slice(0, 200)}`);
  }
}

function request(step) {
  const res = http.get(`${BASE_URL}${pathFor(step)}`, {
    headers: { Accept: 'text/html' },
    responseType: 'none',
    redirects: 0,
    tags: { step, name: step },
  });
  check(res, { [`${step} status is 200`]: (r) => r.status === 200 }, { step });
}

function nextStep() {
  return CYCLE[(__ITER + __VU) % CYCLE.length];
}

export function setup() {
  const home = http.get(`${BASE_URL}/`, { headers: { Accept: 'text/html' }, redirects: 0, tags: { name: 'setup_home' } });
  if (home.status !== 200) {
    throw new Error(`the home page returned status ${home.status}`);
  }
  if (SCENARIO === 'editor') {
    signIn();
  }
  return {};
}

let signedIn = false;

export function visitor() {
  request(nextStep());
}

export function editor() {
  if (!signedIn) {
    signIn();
    signedIn = true;
  }
  request(nextStep());
}

export function handleSummary(data) {
  const out = {};
  out[SUMMARY_PATH] = JSON.stringify(data);
  out.stdout = `k6 ${SCENARIO} with ${VUS} vus for ${DURATION} finished, summary written to ${SUMMARY_PATH}\n`;
  return out;
}
