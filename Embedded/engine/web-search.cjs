// Web search that follows the conversation's model. The stock engine searches through DeepSeek for
// every conversation, so a person chatting with OpenAI would still send each query to DeepSeek.
// Here a conversation on a DeepSeek route searches through DeepSeek as before; any other searches
// with OpenAI's hosted web_search tool (Responses API) on the key of an OpenAI channel the person
// added on the app's own API key page; with neither, there is no search rather than a query sent to a
// service the person did not choose. Adapted from the dsh-web-search-openai host plugin.
//
// The search model is the one picked on the app's 联网搜索 page (`<DSH_HOME>/web-search.json`,
// `{"model": "…"}`), read on every search. Without one: an OpenAI API key (`sk-…`) searches with
// SEARCH_MODEL; a Sign in with ChatGPT token, which accepts only the account's own models, searches
// with a model from that channel's list (the account's `/v1/models`).

const fs = require('node:fs');
const path = require('node:path');

const PROVIDER_ID = 'pallas-web-search';
const DEEPSEEK_ID = 'deepseek-official';
const SEARCH_MODEL = 'gpt-5.4-mini';
const OPENAI_HOST = 'api.openai.com';
const SETTINGS_FILE = 'web-search.json';

class WebError extends Error {
  constructor(message, code, options) {
    super(message, options);
    this.name = 'WebError';
    this.code = code;
  }
}

function apiURL(raw) {
  try {
    const url = new URL(raw);
    if (url.protocol === 'https:' && !url.username && !url.password) return url;
  } catch {}
}

/** The llm-pi-ai channels ({route: {baseURL, apiKeyEnv, …}}) as the settings service has them now. */
function channels(ctx) {
  try {
    const section = ctx.get('settings')?.describe({ redactSecrets: true })?.find(entry => entry.ns === 'llm-pi-ai');
    const providers = section?.value?.providers;
    return providers && typeof providers === 'object' ? providers : {};
  } catch { return {}; }
}

function isDeepSeekRoute(ctx, route) {
  if (typeof route !== 'string' || route === '') return false;
  const base = channels(ctx)[route]?.baseURL;
  if (!base) return route.startsWith('deepseek');
  const hostname = apiURL(base)?.hostname ?? '';
  return hostname === 'deepseek.com' || hostname.endsWith('.deepseek.com');
}

/** The OpenAI channels with a key reference, the conversation's own route first. */
function openAIChannels(ctx, route) {
  const entries = Object.entries(channels(ctx))
    .filter(([, profile]) => apiURL(profile?.baseURL)?.host === OPENAI_HOST &&
      typeof profile?.apiKeyEnv === 'string' && profile.apiKeyEnv !== '');
  entries.sort(([a], [b]) => (a === route ? -1 : b === route ? 1 : 0));
  return entries.map(([, profile]) => profile);
}

function openAIRefs(ctx, route) {
  return openAIChannels(ctx, route).map(profile => profile.apiKeyEnv);
}

/** The first OpenAI channel whose key resolves (and passes `accept`): its key and its model ids. */
async function openAIKey(ctx, route, accept = () => true) {
  const credentials = ctx.get('credentials');
  if (!credentials) return undefined;
  for (const profile of openAIChannels(ctx, route)) {
    try {
      const value = (await credentials.resolve(profile.apiKeyEnv))?.value;
      if (typeof value === 'string' && value.length > 0 && accept(value)) return { key: value, models: modelIds(profile) };
    } catch {}
  }
  return undefined;
}

function modelIds(profile) {
  const list = Array.isArray(profile?.models) ? profile.models : [];
  return list.map(entry => (typeof entry === 'string' ? entry : entry?.id)).filter(id => typeof id === 'string' && id !== '');
}

/** OpenAI API keys start with `sk-`; anything else sent to api.openai.com is a Sign in with ChatGPT token (as pi-ai tells them apart). */
function isChatGPTToken(key) {
  return !key.startsWith('sk-');
}

/** The model picked on the app's 联网搜索 page, or '' for automatic. */
function chosenModel(home = process.env.DSH_HOME) {
  if (!home) return '';
  try {
    const value = JSON.parse(fs.readFileSync(path.join(home, SETTINGS_FILE), 'utf8'))?.model;
    return typeof value === 'string' ? value.trim() : '';
  } catch { return ''; }
}

/** A ChatGPT account's own lightest model: a `luna`, else a `mini`, else the first it lists. */
function accountModel(models) {
  return models.find(id => /luna/i.test(id)) ?? models.find(id => /mini/i.test(id)) ?? models[0];
}

function searchModel(key, models, chosen = chosenModel()) {
  if (chosen) return chosen;
  if (!isChatGPTToken(key)) return SEARCH_MODEL;
  return accountModel(models) ?? SEARCH_MODEL;
}

async function hasOpenAIKey(ctx, route) {
  const credentials = ctx.get('credentials');
  if (!credentials) return false;
  for (const ref of openAIRefs(ctx, route)) {
    try { if ((await credentials.describe(ref)).configured) return true; } catch {}
  }
  return false;
}

/** http(s) only; drops the `utm_source=openai` OpenAI appends to citations. */
function cleanUrl(raw) {
  if (typeof raw !== 'string') return undefined;
  let url;
  try { url = new URL(raw); } catch { return undefined; }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return undefined;
  if (url.searchParams.get('utm_source') === 'openai') url.searchParams.delete('utm_source');
  return url.href;
}

/** A Responses body as the web seam's result; no web_search_call means the model answered from memory. */
function mapResponse(body) {
  const output = Array.isArray(body?.output) ? body.output : [];
  const calls = output.filter(item => item?.type === 'web_search_call');
  if (calls.length === 0) throw new WebError('OpenAI returned no web_search_call; the model answered without searching', 'WEB_PROVIDER_ERROR');
  const sources = [];
  const byUrl = new Map();
  const add = (raw, title) => {
    const url = cleanUrl(raw);
    if (url === undefined) return;
    const known = byUrl.get(url);
    if (known) { if (known.title === undefined && typeof title === 'string' && title) known.title = title; return; }
    const source = { url, ...(typeof title === 'string' && title ? { title } : {}) };
    byUrl.set(url, source);
    sources.push(source);
  };
  const texts = [];
  for (const item of output) {
    if (item?.type !== 'message' || !Array.isArray(item.content)) continue;
    for (const part of item.content) {
      if (part?.type !== 'output_text' || typeof part.text !== 'string') continue;
      if (part.text.trim()) texts.push(part.text.trim());
      for (const note of Array.isArray(part.annotations) ? part.annotations : []) {
        if (note?.type === 'url_citation') add(note.url, note.title);
      }
    }
  }
  for (const call of calls) for (const s of Array.isArray(call.action?.sources) ? call.action.sources : []) add(s?.url, s?.title);
  const content = texts.join('\n\n');
  return { ...(content ? { content } : {}), sources, truncated: false };
}

/**
 * A streamed Responses answer (server-sent events) as the body a plain request returns: the final
 * `response.completed` (or `response.failed` / `error`) response, its output filled from the
 * `response.output_item.done` events when the final event leaves it empty.
 */
function fromEvents(text) {
  const items = [];
  let final;
  for (const line of text.split(/\r?\n/)) {
    if (!line.startsWith('data:')) continue;
    let event;
    try { event = JSON.parse(line.slice(5).trim()); } catch { continue; }
    if (event?.type === 'response.output_item.done' && event.item) items.push(event.item);
    else if (event?.type === 'response.completed' || event?.type === 'response.failed' || event?.type === 'response.incomplete') final = event.response;
    else if (event?.type === 'error') final = { error: { message: event.message ?? event.error?.message ?? 'stream error' } };
  }
  if (final === undefined) return undefined;
  if (final.error == null && !(Array.isArray(final.output) && final.output.length > 0)) final = { ...final, output: items };
  return final;
}

/** The reason in an error body: `error.message`, `error` or `detail` as a string, else the start of the raw text. */
function errorDetail(body, text) {
  const reason = [body?.error?.message, body?.error, body?.detail, body?.message].find(v => typeof v === 'string' && v.trim());
  const raw = reason ?? text.trim().slice(0, 300);
  return raw ? `: ${raw}` : '';
}

function aborted(signal, cause) {
  return new WebError('Web search aborted', 'WEB_ABORTED', { cause: signal?.aborted ? signal.reason : cause });
}

async function searchOpenAI(ctx, route, request, signal) {
  if (signal?.aborted) throw aborted(signal);
  const found = await openAIKey(ctx, route);
  if (!found) throw new WebError('No OpenAI API key is saved for web search; the person can add one on the app\'s own API key page', 'WEB_PROVIDER_CREDENTIAL_MISSING');
  const endpoint = `https://${OPENAI_HOST}/v1/responses`;
  const model = searchModel(found.key, found.models);
  // Sign in with ChatGPT answers only as a stream ("Stream must be set to true").
  const stream = isChatGPTToken(found.key);
  let response;
  try {
    response = await fetch(endpoint, {
      method: 'POST',
      redirect: 'error',
      headers: { authorization: `Bearer ${found.key}`, 'content-type': 'application/json', accept: stream ? 'text/event-stream' : 'application/json' },
      body: JSON.stringify({
        model,
        // A list, not a bare string: Sign in with ChatGPT refuses a string input ("Input must be a list").
        input: [{ role: 'user', content: [{ type: 'input_text', text: `Search the web for: ${request.query}\nAnswer briefly and cite the pages you used.` }] }],
        tools: [{ type: 'web_search' }],
        tool_choice: 'required',
        include: ['web_search_call.action.sources'],
        store: false,
        ...(stream ? { stream: true } : {}),
      }),
      ...(signal ? { signal } : {}),
    });
  } catch (error) {
    if (signal?.aborted || error?.name === 'AbortError') throw aborted(signal, error);
    throw new WebError(`OpenAI search request failed: ${String(error)}`, 'WEB_PROVIDER_ERROR', { cause: error });
  }
  let text = '', body;
  try { text = await response.text(); } catch (error) {
    if (signal?.aborted || error?.name === 'AbortError') throw aborted(signal, error);
  }
  try { body = response.ok && stream ? fromEvents(text) : JSON.parse(text); } catch {}
  if (!response.ok || body?.error != null) {
    throw new WebError(`OpenAI search with ${model} failed (HTTP ${response.status})${errorDetail(body, text)}`, 'WEB_PROVIDER_ERROR');
  }
  if (body === undefined) throw new WebError(stream ? 'OpenAI search ended without a final response' : 'OpenAI returned a response body that is not JSON', 'WEB_PROVIDER_ERROR');
  return mapResponse(body);
}

/** Register the provider on the app-owned engine's web service. */
function attach(ctx) {
  ctx.inject(['web'], webCtx => {
    const web = webCtx.web;
    const deepseek = () => web.searchProviders?.get(DEEPSEEK_ID);
    try {
      web.registerSearchProvider({
        id: PROVIDER_ID,
        available: () => true,
        ready: async llmProvider => {
          if (!llmProvider) return false;
          if (isDeepSeekRoute(webCtx, llmProvider)) return (await deepseek()?.ready?.(llmProvider)) ?? false;
          return hasOpenAIKey(webCtx, llmProvider);
        },
        search: async (request, signal) => {
          // The agent loop establishes an async initiator for each turn. Readiness for a
          // different conversation can run between this turn's model request and tool execution.
          const route = webCtx.get('agents')?.currentInitiator()?.session.requestContext()?.provider;
          if (!route) throw new WebError('Web search requires a conversation model', 'WEB_PROVIDER_UNAVAILABLE');
          if (isDeepSeekRoute(webCtx, route)) {
            const provider = deepseek();
            if (!provider) throw new WebError('DeepSeek search is not available on this device', 'WEB_PROVIDER_ERROR');
            return provider.search(request, signal);
          }
          return searchOpenAI(webCtx, route, request, signal);
        },
      });
    } catch (error) {
      // tool-fs may start more than once; the first registration stays.
      if (error?.code !== 'WEB_DUPLICATE_PROVIDER') throw error;
    }
  });
}

module.exports = { attach, mapResponse, fromEvents, searchModel, chosenModel, openAIKey, isChatGPTToken, PROVIDER_ID, SETTINGS_FILE };
