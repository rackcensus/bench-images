const fs = require('fs');

const [base, manifestPath] = process.argv.slice(2);
const ORIGIN = base;
const OWNER = { name: 'Rack Census', email: 'owner@example.com', password: 'Tq7mVx2pLr9wKd4nB8cZ' };
const POSTS = 200;
const DRAFTS = 20;
const MEMBERS = 1000;
const TAGS = ['Hosting', 'Linux', 'Databases', 'Networking', 'Security', 'Performance', 'Backups', 'Containers', 'Monitoring', 'Guides'];
const WORDS = ('server rack cloud latency network packet kernel thread memory cache disk storage volume backup restore snapshot ' +
  'cluster region zone uptime outage incident alert metric graph query index table schema replica primary failover load ' +
  'balancer proxy certificate domain record route firewall port socket process worker queue job schedule deploy release ' +
  'build image container registry pipeline config secret token session request response header payload budget plan ' +
  'provider customer team review benchmark result baseline trend spike throughput bandwidth transfer quota limit swap ' +
  'the a an and or but with without into over under between across before after during while because so then also ' +
  'quickly slowly carefully simply usually rarely often every each some many most few several small large fast cheap ' +
  'reliable stable noisy busy quiet modern legacy shared dedicated managed bare virtual physical remote local').split(' ');

let state = 20261010;
function random() {
  state = (state + 0x6d2b79f5) | 0;
  let t = state;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
function between(low, high) {
  return low + Math.floor(random() * (high - low + 1));
}
function pick(list) {
  return list[Math.floor(random() * list.length)];
}
function words(count) {
  const out = [];
  for (let i = 0; i < count; i += 1) out.push(pick(WORDS));
  return out.join(' ');
}
function sentence() {
  const text = words(between(8, 20));
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}.`;
}
function paragraph() {
  const out = [];
  for (let i = between(3, 6); i > 0; i -= 1) out.push(sentence());
  return `<p>${out.join(' ')}</p>`;
}
function title() {
  const text = words(between(4, 8));
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}`;
}
function body() {
  const parts = [];
  for (let section = between(3, 5); section > 0; section -= 1) {
    parts.push(`<h2>${title()}</h2>`);
    for (let i = between(2, 4); i > 0; i -= 1) parts.push(paragraph());
    if (random() < 0.4) parts.push(`<ul>${[0, 1, 2, 3].map(() => `<li>${sentence()}</li>`).join('')}</ul>`);
    if (random() < 0.2) parts.push(`<blockquote>${sentence()}</blockquote>`);
    if (random() < 0.2) parts.push(`<pre><code>${words(12)}</code></pre>`);
  }
  return parts.join('\n');
}

let cookie = null;

async function api(method, path, payload, options = {}) {
  const headers = { Origin: ORIGIN, Accept: 'application/json' };
  if (payload !== undefined) headers['Content-Type'] = 'application/json';
  if (cookie) headers.Cookie = cookie;
  const response = await fetch(`${base}/ghost/api/admin${path}`, { method, headers, body: payload === undefined ? undefined : JSON.stringify(payload) });
  const text = await response.text();
  if (!response.ok && !options.allow) {
    throw new Error(`${method} ${path} returned ${response.status}: ${text.slice(0, 300)}`);
  }
  const setCookie = response.headers.get('set-cookie');
  if (setCookie && setCookie.includes('ghost-admin-api-session=')) cookie = setCookie.split(';')[0];
  const json = (response.headers.get('content-type') || '').includes('json') && text ? JSON.parse(text) : null;
  return { status: response.status, json };
}

async function waitForGhost() {
  for (let attempt = 0; attempt < 180; attempt += 1) {
    try {
      const response = await fetch(`${base}/ghost/api/admin/authentication/setup/`, { headers: { Origin: ORIGIN } });
      if (response.ok) return (await response.json()).setup[0].status;
    } catch (error) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      continue;
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error('ghost never answered the setup endpoint');
}

async function browseAll(path) {
  const out = [];
  for (let page = 1; ; page += 1) {
    const { json } = await api('GET', `${path}${path.includes('?') ? '&' : '?'}limit=100&page=${page}`);
    const key = Object.keys(json).find((name) => name !== 'meta');
    out.push(...json[key]);
    if (!json.meta.pagination.next) return out;
  }
}

async function main() {
  if (await waitForGhost()) throw new Error('ghost is already set up, only seed an empty database');
  await api('POST', '/authentication/setup/', { setup: [{ name: OWNER.name, email: OWNER.email, password: OWNER.password, blogTitle: 'Rack Census Notes' }] });
  await api('POST', '/session/', { username: OWNER.email, password: OWNER.password });
  const { json: me } = await api('GET', '/users/me/');
  const owner = me.users[0];

  console.log(`creating ${TAGS.length} tags`);
  for (const name of TAGS) {
    await api('POST', '/tags/', { tags: [{ name, description: sentence() }] });
  }

  console.log(`creating ${POSTS} published posts and ${DRAFTS} drafts`);
  const start = Date.UTC(2024, 9, 10);
  const span = Date.UTC(2026, 8, 30) - start;
  for (let i = 0; i < POSTS + DRAFTS; i += 1) {
    const draft = i >= POSTS;
    const tags = [];
    while (tags.length < between(1, 3)) {
      const name = pick(TAGS);
      if (!tags.includes(name)) tags.push(name);
    }
    const post = {
      title: `${title()} ${i + 1}`,
      html: body(),
      custom_excerpt: sentence(),
      tags: tags.map((name) => ({ name })),
      status: draft ? 'draft' : 'published',
      featured: !draft && i % 25 === 0,
    };
    if (!draft) post.published_at = new Date(start + Math.floor((span * i) / POSTS)).toISOString();
    await api('POST', '/posts/?source=html', { posts: [post] });
  }

  console.log(`creating ${MEMBERS} members`);
  for (let i = 0; i < MEMBERS; i += 1) {
    await api('POST', '/members/', { members: [{ email: `member${i + 1}@example.com`, name: `Member ${i + 1}`, subscribed: random() < 0.8 }] });
  }

  const published = await browseAll('/posts/?filter=status:published&fields=id,slug,url');
  const drafts = await browseAll('/posts/?filter=status:draft&fields=id,slug');
  const tags = await browseAll('/tags/?fields=id,slug');
  const members = await api('GET', '/members/?limit=1');
  const postPaths = published.map((post) => new URL(post.url).pathname).sort();
  const manifest = {
    post_paths: postPaths,
    tag_paths: tags.map((tag) => `/tag/${tag.slug}/`).sort(),
    author_path: `/author/${owner.slug}/`,
    draft_post_ids: drafts.map((post) => post.id).sort(),
    staff_email: OWNER.email,
    password: OWNER.password,
    counts: { posts: published.length, drafts: drafts.length, tags: tags.length, members: members.json.meta.pagination.total },
    versions: { ghost: (await api('GET', '/config/')).json.config.version },
  };
  if (manifest.counts.posts < POSTS || manifest.counts.drafts < DRAFTS || manifest.counts.members !== MEMBERS) {
    throw new Error(`seed counts are off: ${JSON.stringify(manifest.counts)}`);
  }
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  console.log(`seeded ${JSON.stringify(manifest.counts)}`);
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
