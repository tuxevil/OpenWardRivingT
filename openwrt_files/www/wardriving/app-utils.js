// OpenWardRivingT — pure dashboard helpers.
//
// Why this file exists separately from app.js:
//   app.js is a flat script that runs in the browser. Most of its logic
//   is bound to DOM elements and timers, which makes it untestable in
//   Node.js. This file contains the *pure* string/option helpers used
//   by app.js, exported in a UMD-style wrapper so:
//     - In the browser, they attach to window.OWRT_UTILS.
//     - In Node, they are available via require('./app-utils.js').
//   That lets us run `node --test` against these helpers in CI without
//   jsdom, jsdom-helpers, or any other heavy test framework.
//
// IMPORTANT: this file must stay free of DOM API calls, network calls,
// and global state mutations. Anything that touches the document or
// window.fetch belongs in app.js (which depends on this file).
(function (root) {
  function esc(v) {
    return String(v == null ? '' : v).replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[c]);
  }

  // dim() wraps a string in a <span> that the CSS uses to dim it.
  // Pure: callers pass in a message and we return HTML.
  function dim(msg) {
    return '<span style="color:var(--c-dim)">' + esc(msg) + '</span>';
  }

  // withApiAuth: attach Authorization: Bearer header for the wardriving
  // API. The CGI accepts both header and query-string tokens; the header
  // is preferred so the token never lands in access logs or Referer
  // headers. Callers that genuinely cannot set a header (window.open for
  // downloads) keep the &token= in the URL as the secondary path.
  function withApiAuth(options) {
    options = options || {};
    if (!root.API_TOKEN) return options;
    const headers = Object.assign({}, options.headers || {});
    if (!headers.Authorization) headers.Authorization = 'Bearer ' + root.API_TOKEN;
    return Object.assign({}, options, { headers });
  }

  // apiUrl: build a /cgi-bin/wardriving_api URL with the token. Callers
  // pass the action and an optional params object; the token is appended
  // as a query param so window.open() downloads work without headers.
  function apiUrl(action, params) {
    let url = '/cgi-bin/wardriving_api?action=' + encodeURIComponent(action);
    if (params) Object.keys(params).forEach(k => {
      url += '&' + encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
    });
    if (root.API_TOKEN) url += '&token=' + encodeURIComponent(root.API_TOKEN);
    return url;
  }

  const utils = { esc, dim, withApiAuth, apiUrl };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = utils;
  } else {
    root.OWRT_UTILS = utils;
  }
})(typeof window !== 'undefined' ? window : globalThis);
