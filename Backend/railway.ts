const queries = new Set(["query FindAuthors($term: String!) { search(query: $term, query_type: \"Author\", per_page: 20, page: 1) { ids } }", "query Authors($ids: [Int!]!) { authors(where: {id: {_in: $ids}}) { id name } }", "query FindBooks($term: String!) { search(query: $term, query_type: \"Book\", per_page: 20, page: 1) { ids } }", "query Books($ids: [Int!]!) { books(where: {id: {_in: $ids}, book_status_id: {_eq: 1}}) { id title slug release_date cached_image contributions { author { id name } } } }", "query BrowseUpcoming($today: date!) { books(where: {book_status_id: {_eq: 1}, release_date: {_gte: $today}}, order_by: [{release_date: asc}, {id: asc}], limit: 100) { id title slug release_date cached_image contributions { author { id name } } } }", "query Upcoming($author: Int!, $today: date!, $offset: Int!) { books(where: {book_status_id: {_eq: 1}, release_date: {_gte: $today}, contributions: {author_id: {_eq: $author}, contributable_type: {_eq: \"Book\"}}}, order_by: [{release_date: asc}, {id: asc}], limit: 100, offset: $offset) { id title slug release_date cached_image contributions { author { id name } } } }"]);

const cache = new Map<string, {expires: number, data: string}>();
let busy = false;
let lastRequest = 0;
const json = (body: unknown, status = 200) => Response.json(body, {status});
function validate(body: any) {
  if (!body || typeof body.query !== "string" || !queries.has(body.query.replace(/\s+/g, " ").trim())) return false;
  const v = body.variables;
  if (!v || typeof v !== "object" || Array.isArray(v)) return false;
  const expected = [...body.query.matchAll(/\$(\w+)\s*:/g)].map(m => m[1]).sort();
  if (JSON.stringify(Object.keys(v).sort()) !== JSON.stringify(expected)) return false;
  for (const [k, x] of Object.entries(v)) {
    if (k === "term" && (typeof x !== "string" || x.trim().length < 1 || x.length > 200)) return false;
    if (k === "ids" && (!Array.isArray(x) || x.length < 1 || x.length > 20 || x.some(i => !Number.isSafeInteger(i) || i <= 0))) return false;
    if (k === "author" && (!Number.isSafeInteger(x) || (x as number) <= 0)) return false;
    if (k === "offset" && (!Number.isSafeInteger(x) || (x as number) < 0 || (x as number) > 10000)) return false;
    if (k === "today" && ![-1,0,1].map(d => new Date(Date.now()+d*86400000).toISOString().slice(0,10)).includes(x as string)) return false;
  }
  return true;
}
Bun.serve({port: Number(Bun.env.PORT || 8080), hostname: "0.0.0.0", async fetch(request) {
  const path = new URL(request.url).pathname;
  if (path === "/health" && request.method === "GET") return json({status: "ok", catalogConfigured: Boolean(Bun.env.HARDCOVER_API_TOKEN?.trim())});
  if (path !== "/catalog") return json({}, 404);
  if (request.method !== "POST") return json({}, 405);
  if (Number(request.headers.get("content-length") || 0) > 16384) return json({}, 413);
  let body;
  try {
    const text = await request.text();
    if (text.length > 16384) return json({}, 413);
    body = JSON.parse(text);
    if (!validate(body)) return json({}, 400);
  } catch { return json({}, 400); }
  const token = Bun.env.HARDCOVER_API_TOKEN?.replace(/^Bearer\s+/, "").trim();
  if (!token) return json({error: "Catalog credentials have not been configured on the server."}, 503);
  const key = JSON.stringify({query: body.query.replace(/\s+/g," ").trim(), variables: Object.fromEntries(Object.entries(body.variables).sort())});
  const hit = cache.get(key);
  if (hit && hit.expires > Date.now()) return new Response(hit.data, {headers: {"Content-Type":"application/json"}});
  if (busy || Date.now() - lastRequest < 1100) return json({}, 429);
  busy = true; lastRequest = Date.now();
  try {
    const result = await fetch("https://api.hardcover.app/v1/graphql", {method:"POST", headers:{"Authorization":"Bearer " + token,"Content-Type":"application/json"},body:key,signal:AbortSignal.timeout(30000)});
    if (!result.ok) return json({}, [401,403,429].includes(result.status) ? result.status : 502);
    const data = await result.text();
    const parsed = JSON.parse(data);
    if (!parsed.errors?.length) {
      if (cache.size >= 1000) cache.clear();
      cache.set(key, {expires:Date.now()+900000,data});
    }
    return new Response(data, {headers:{"Content-Type":"application/json"}});
  } catch { return json({},502); }
  finally {busy = false;}
}});
