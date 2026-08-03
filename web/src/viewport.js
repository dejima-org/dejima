// Keeps the terminal inside the space the browser is actually showing.
//
// A soft keyboard does not resize the layout viewport on either platform - it
// covers it. Left alone, the bottom of the terminal ends up underneath the
// keyboard, and the bottom of the terminal is where the shell prompt is. The
// visual viewport is the only thing that knows the difference.
(function (D) {
  'use strict';

  // opts: {app, onFit}
  function createViewport(opts) {
    var pending = false;

    function apply() {
      pending = false;
      var vv = window.visualViewport;
      var height = vv ? vv.height : window.innerHeight;
      var offset = vv ? vv.offsetTop : 0;
      opts.app.style.height = height + 'px';
      // The app is position: fixed, so it is pinned to the layout viewport;
      // shifting it by the visual viewport's offset is what keeps it on screen
      // when iOS scrolls the layout viewport to reveal a focused field.
      opts.app.style.transform = offset ? 'translateY(' + offset + 'px)' : '';
      opts.onFit();
    }

    // Coalesced: a keyboard opening emits a burst of resize and scroll events,
    // and fitting the terminal on each one is both visibly janky and a burst
    // of resize messages to the far end.
    function schedule() {
      if (pending) return;
      pending = true;
      requestAnimationFrame(apply);
    }

    function attach() {
      var vv = window.visualViewport;
      if (vv) {
        vv.addEventListener('resize', schedule);
        vv.addEventListener('scroll', schedule);
      }
      window.addEventListener('resize', schedule);
      window.addEventListener('orientationchange', schedule);
      apply();
    }

    return { attach: attach, refresh: schedule };
  }

  D.viewport = { createViewport: createViewport };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
