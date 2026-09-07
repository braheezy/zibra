// Media state lives with the document's native controller. Polling uses the
// existing realm timers, so navigation retires both callbacks and promises.
function HTMLMediaElement() { throw new TypeError('Illegal constructor'); }
HTMLMediaElement.prototype = Object.create(Node.prototype);
Object.defineProperty(HTMLMediaElement.prototype, 'constructor', {value: HTMLMediaElement});
function HTMLAudioElement() { throw new TypeError('Illegal constructor'); }
HTMLAudioElement.prototype = Object.create(HTMLMediaElement.prototype);
Object.defineProperty(HTMLAudioElement.prototype, 'constructor', {value: HTMLAudioElement});
function Audio(src) {
  if (!new.target) throw new TypeError('Audio requires new');
  var audio = document.createElement('audio');
  audio.preload = 'auto';
  if (src !== undefined) audio.src = String(src);
  return audio;
}
Audio.prototype = HTMLAudioElement.prototype;
function __mediaCall(node, command, value) {
  return __native.media(node.handle, command, value === undefined ? 0 : value);
}
function __mediaError(name) { var error = new DOMException(name, name); if (name === "AbortError") error.code = 20; return error; }
function __mediaSettle(node, name, exceptRevision) {
  var pending = node.__mediaPromises || [];
  node.__mediaPromises = [];
  for (var i = 0; i < pending.length; i++) {
    if (exceptRevision !== undefined && pending[i][2] === exceptRevision) { node.__mediaPromises.push(pending[i]); continue; }
    if (name) pending[i][1](__mediaError(name)); else pending[i][0]();
  }
}
function __mediaWatch(handle) {
  var node = wrapNode(handle);
  if (!node || node.__mediaTimer) return;
  node.__mediaTimer = true;
  setTimeout(function tick() {
    node.__mediaTimer = false;
    var state = __mediaCall(node, 'poll');
    var events = state[11] ? state[11].split(',') : [];
    for (var i = 0; i < events.length; i++) {
      var type = events[i];
      if (type === 'playing') __mediaSettle(node, null);
      if (type === 'error') __mediaSettle(node, 'NotSupportedError');
      if (type === 'abort' || type === 'emptied') __mediaSettle(node, 'AbortError', state[13]);
      if (type === 'pause' && state[2]) __mediaSettle(node, 'AbortError');
      if (type === 'seeked') node.__mediaSeeking = false;
      var event = new Event(type, {bubbles: false, cancelable: false});
      event.bubbles = false;
      var inline = node.getAttribute('on' + type);
      var handler = null;
      if (inline && typeof node['on' + type] !== 'function') {
        try { handler = new Function('event', inline); } catch (error) {}
      }
      dispatchNodeEvent(node, event, handler);
      if (__mediaCall(node, 'snapshot')[13] !== state[13]) break;
    }
    // Events may change src, pause, or detach the element. Re-read the live
    // state instead of scheduling from the pre-listener snapshot.
    state = __mediaCall(node, 'snapshot');
    if (state[4] === 2 || !state[2] || (node.__mediaPromises || []).length || events.length)
      __mediaWatch(handle);
  }, 50);
}
HTMLMediaElement.prototype.load = function() {
  __mediaSettle(this, 'AbortError');
  __mediaCall(this, 'load');
  __mediaWatch(this.handle);
};
HTMLMediaElement.prototype.play = function() {
  var node = this;
  return new Promise(function(resolve, reject) {
    var state = __mediaCall(node, 'play');
    if (state[12] || state[6]) {
      reject(__mediaError(state[12] === 'NotAllowedError' ? 'NotAllowedError' : 'NotSupportedError'));
      return;
    }
    if (!node.__mediaPromises) node.__mediaPromises = [];
    node.__mediaPromises.push([resolve, reject, state[13]]);
    __mediaWatch(node.handle);
  });
};
HTMLMediaElement.prototype.pause = function() {
  __mediaCall(this, 'pause');
  __mediaSettle(this, 'AbortError');
  __mediaWatch(this.handle);
};
HTMLMediaElement.prototype.canPlayType = function(type) {
  var mime = String(type).split(';')[0].trim().toLowerCase();
  return ['audio/wav','audio/wave','audio/x-wav','audio/mpeg','audio/mp3',
    'audio/flac','audio/x-flac','audio/ogg','application/ogg','audio/aac','audio/qoa'].indexOf(mime) >= 0 ? 'maybe' : '';
};
(function() {
  var proto = HTMLMediaElement.prototype;
  [['duration',0,false],['paused',2,true],['ended',3,true],['networkState',4,false],['readyState',5,false],['currentSrc',10,false]].forEach(function(field) {
    Object.defineProperty(proto, field[0], {enumerable: true, configurable: true,
      get: function() { var value = __mediaCall(this, field[0] === 'currentSrc' ? 'source' : 'snapshot')[field[1]]; return field[2] ? !!value : value; }});
  });
  Object.defineProperty(proto, 'currentTime', {enumerable: true, configurable: true,
    get: function() { return __mediaCall(this, 'snapshot')[1]; },
    set: function(value) {
      value = Number(value);
      if (!isFinite(value)) throw new TypeError('currentTime must be finite');
      var state = __mediaCall(this, 'seek', Math.max(0, value));
      if (state[12]) throw __mediaError(state[12]);
      this.__mediaSeeking = state[5] > 0;
      __mediaWatch(this.handle);
    }});
  Object.defineProperty(proto, 'seeking', {get: function() { return !!this.__mediaSeeking; }});
  Object.defineProperty(proto, 'volume', {enumerable: true, configurable: true,
    get: function() { return __mediaCall(this, 'snapshot')[7]; },
    set: function(value) {
      value = Number(value);
      if (!isFinite(value) || value < 0 || value > 1) throw __mediaError('IndexSizeError');
      __mediaCall(this, 'volume', value); __mediaWatch(this.handle);
    }});
  Object.defineProperty(proto, 'muted', {enumerable: true, configurable: true,
    get: function() { return !!__mediaCall(this, 'snapshot')[8]; },
    set: function(value) { __mediaCall(this, 'muted', value ? 1 : 0); __mediaWatch(this.handle); }});
  [['controls','controls'],['autoplay','autoplay'],['loop','loop'],['defaultMuted','muted']].forEach(function(pair) {
    Object.defineProperty(proto, pair[0], {enumerable: true, configurable: true,
      get: function() { return this.hasAttribute(pair[1]); },
      set: function(value) { if (value) this.setAttribute(pair[1], ''); else this.removeAttribute(pair[1]); __mediaWatch(this.handle); }});
  });
  Object.defineProperty(proto, 'preload', {enumerable: true, configurable: true,
    get: function() { var value = (this.getAttribute('preload') || '').toLowerCase(); return value === 'none' ? 'none' : value === 'metadata' ? 'metadata' : 'auto'; },
    set: function(value) { this.setAttribute('preload', String(value)); __mediaWatch(this.handle); }});
  Object.defineProperty(proto, 'crossOrigin', {enumerable: true, configurable: true,
    get: function() { var value = this.getAttribute('crossorigin'); return value === null ? null : value.toLowerCase() === 'use-credentials' ? 'use-credentials' : 'anonymous'; },
    set: function(value) { if (value === null) this.removeAttribute('crossorigin'); else this.setAttribute('crossorigin', String(value)); __mediaCall(this, 'snapshot'); __mediaWatch(this.handle); }});
  Object.defineProperty(proto, 'src', {enumerable: true, configurable: true,
    get: function() { var value = this.getAttribute('src'); if (value === null) return ''; try { return new URL(value, document.baseURI).href; } catch (error) { return value; } },
    set: function(value) { __mediaSettle(this, 'AbortError'); this.setAttribute('src', String(value)); __mediaCall(this, 'snapshot'); __mediaWatch(this.handle); }});
  Object.defineProperty(proto, 'error', {get: function() {
    var code = __mediaCall(this, 'snapshot')[6];
    return code ? Object.assign(Object.create(MediaError.prototype), {code: code, message: 'Audio could not be loaded or played'}) : null;
  }});
  ['buffered','seekable'].forEach(function(name) {
    Object.defineProperty(proto, name, {get: function() {
      var state = __mediaCall(this, 'snapshot');
      var end = state[5] >= 1 ? state[0] : 0;
      return {length: end > 0 ? 1 : 0,
        start: function(index) { if (index !== 0 || !(end > 0)) throw __mediaError('IndexSizeError'); return 0; },
        end: function(index) { if (index !== 0 || !(end > 0)) throw __mediaError('IndexSizeError'); return end; }};
    }});
  });
  ['NETWORK_EMPTY','NETWORK_IDLE','NETWORK_LOADING','NETWORK_NO_SOURCE'].forEach(function(name, value) {
    Object.defineProperty(HTMLMediaElement, name, {value: value}); Object.defineProperty(proto, name, {value: value});
  });
  ['HAVE_NOTHING','HAVE_METADATA','HAVE_CURRENT_DATA','HAVE_FUTURE_DATA','HAVE_ENOUGH_DATA'].forEach(function(name, value) {
    Object.defineProperty(HTMLMediaElement, name, {value: value}); Object.defineProperty(proto, name, {value: value});
  });
})();
function MediaError() { throw new TypeError('Illegal constructor'); }
['MEDIA_ERR_ABORTED','MEDIA_ERR_NETWORK','MEDIA_ERR_DECODE','MEDIA_ERR_SRC_NOT_SUPPORTED'].forEach(function(name, index) {
  Object.defineProperty(MediaError, name, {value: index + 1});
  Object.defineProperty(MediaError.prototype, name, {value: index + 1});
});

// Install only after the prototypes exist, then specialize wrappers created
// during bootstrap. Later wrappers are specialized once by wrapNode.
var __specializeMediaNode = function(node) {
  if ((node.tagName || '').toLowerCase() === 'audio')
    Object.setPrototypeOf(node, HTMLAudioElement.prototype);
};
Object.keys(NODE_WRAPPERS).forEach(function(handle) { __specializeMediaNode(NODE_WRAPPERS[handle]); });
