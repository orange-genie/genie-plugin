/* ─────────────────────────────────────────────────────────────────────────────────────────
   THE ICON SET — ours, one file, every page
   =============================================================================
   Add <script src="/embed/icons.js"></script> as the FIRST thing inside <body> and the whole
   set is available as <svg class="ic"><use href="#i-NAME"/></svg>. Nothing else to copy.

   WHY A FILE AND NOT A BLOCK PASTED PER PAGE: a sprite copied onto four pages is four sprites,
   and the third time someone nudges a stroke it only lands on the page they were looking at.
   One definition or the set stops being a set.

   WHY NOT A FONT OR A GLYPH CHARACTER: what was here before was ◇ ◈ ◆ ⚙ ▾ — whatever the
   reader's font happened to draw, at whatever weight it happened to have. That is why the rail
   read as unfinished next to a real product's sidebar. These are drawn, so they are the same
   everywhere and they inherit colour from the button they sit in.

   ONE FAMILY, so the icons read as a set rather than as pictures borrowed from six places:
     · 20x20 box, 1.6 stroke, round caps and joins, currentColor, no fill except accents
     · one silhouette each — square, layers, rings, diagonal, bars — because at 17px the detail
       is gone and only the outline survives
     · nothing that needs a background colour behind it: the slider knobs BREAK their rails
       instead of sitting on top of them, so the set works on any surface

   TWO THINGS LEARNED HERE, both cost a round trip:
     · a cog does not survive 17px. Eight teeth around a small hub average into a sun. The
       settings mark is sliders for that reason, not for taste.
     · a `background:` shorthand later in the same rule silently resets background-image to
       none. The search magnifier is applied as background-image, so that rule must say
       background-color.

   i-agent IS THE ACTUAL LOGO, not a likeness of it. It is wobbels_logo_clean.svg scaled from
   its 2048 box into this 20 box — every coordinate divided by 102.4, nothing eyeballed. What
   was here before was hand-drawn from memory of the same mark and was close enough to look
   right and wrong at the same time, which is the worst way for a logo to be wrong.

   It is the one solid icon in the set. The logo is a filled orange frame around a black square,
   so it is drawn as a filled path with fill-rule="evenodd": the outer rounded rect and the inner
   one are subpaths of a single path, and evenodd punches the inner out to leave the frame. That
   also sidesteps a fight with .ic's stroke-width, which a CSS rule would win over any width set
   on the element. It still takes currentColor, so it goes orange when its rail is active.

   TO REGENERATE after a logo change: divide every coordinate in the source SVG by 102.4. Do not
   redraw it by hand.

   Injected next to this script tag rather than written at the end, so the symbols exist before
   the markup that references them is parsed — no flash of empty icons.
   ───────────────────────────────────────────────────────────────────────────────────────── */
(function () {
  "use strict";
  var SPRITE = 
    '<svg width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false"><defs>'
    + '  <symbol id="i-compose" viewBox="0 0 20 20">'
    + '    <path d="M10.6 3.6H4.8A1.8 1.8 0 0 0 3 5.4v9.8A1.8 1.8 0 0 0 4.8 17h9.8a1.8 1.8 0 0 0 1.8-1.8V9.4"/>'
    + '    <path d="M14.1 3.2a1.85 1.85 0 0 1 2.7 2.5l-6.2 6.2-3.2.7.7-3.2z"/>'
    + '  </symbol>'
    + '  <symbol id="i-search" viewBox="0 0 20 20">'
    + '    <circle cx="9" cy="9" r="5.3"/><path d="M12.9 12.9 17.2 17.2"/>'
    + '  </symbol>'
    + '  <symbol id="i-agent" viewBox="0 0 20 20">'
    + '<path fill="currentColor" stroke="none" fill-rule="evenodd" d="M4.883,2.246 H15.117 A2.637,2.637 0 0 1 17.754,4.883 V15.117 A2.637,2.637 0 0 1 15.117,17.754 H4.883 A2.637,2.637 0 0 1 2.246,15.117 V4.883 A2.637,2.637 0 0 1 4.883,2.246 Z M6.055,4.297 H13.945 A1.758,1.758 0 0 1 15.703,6.055 V13.945 A1.758,1.758 0 0 1 13.945,15.703 H6.055 A1.758,1.758 0 0 1 4.297,13.945 V6.055 A1.758,1.758 0 0 1 6.055,4.297 Z"/>'
    + '<rect x="7.422" y="8.203" width="1.367" height="2.148" rx="0.684" fill="currentColor" stroke="none"/>'
    + '<rect x="11.211" y="8.203" width="1.367" height="2.148" rx="0.684" fill="currentColor" stroke="none"/>'
    + '<rect x="8.73" y="12.305" width="2.539" height="0.43" rx="0.215" fill="currentColor" stroke="none"/>'
    + '  </symbol>'
    + '  <symbol id="i-packs" viewBox="0 0 20 20">'
    + '    <path d="M10 2.9 3 6.3l7 3.4 7-3.4-7-3.4Z"/>'
    + '    <path d="M3 10.1 10 13.5 17 10.1"/><path d="M3 13.7 10 17.1 17 13.7"/>'
    + '  </symbol>'
    + '  <symbol id="i-bounty" viewBox="0 0 20 20">'
    + '    <circle cx="10" cy="10" r="7"/><circle cx="10" cy="10" r="3.2"/>'
    + '    <circle cx="10" cy="10" r="1.15" fill="currentColor" stroke="none"/>'
    + '  </symbol>'
    + '  <symbol id="i-earn" viewBox="0 0 20 20">'
    + '    <path d="M3 14.6 7.4 9.9l3.1 2.7L17 5.4"/><path d="M12.6 5.4H17v4.4"/>'
    + '  </symbol>'
    + '  <symbol id="i-gear" viewBox="0 0 20 20">'
    + '    <path d="M3 6h2.1M8.9 6H17M3 10h8.1M14.9 10H17M3 14h4.6M11.4 14H17"/>'
    + '    <circle cx="7" cy="6" r="1.9"/><circle cx="13" cy="10" r="1.9"/><circle cx="9.5" cy="14" r="1.9"/>'
    + '  </symbol>'
    + '  <symbol id="i-wallet" viewBox="0 0 20 20">'
    + '<path d="M3 6.5A2 2 0 0 1 5 4.5h9A1.5 1.5 0 0 1 15.5 6v1"/>'
    + '<path d="M3 6.5v8A1.5 1.5 0 0 0 4.5 16h11a1.5 1.5 0 0 0 1.5-1.5v-6A1.5 1.5 0 0 0 15.5 7H4.5A1.5 1.5 0 0 1 3 5.5"/>'
    + '<circle cx="13.4" cy="11.5" r="1.05" fill="currentColor" stroke="none"/>'
    + '  </symbol>'
    + '  <symbol id="i-mail" viewBox="0 0 20 20">'
    + '<rect x="2.5" y="4.5" width="15" height="11" rx="2"/>'
    + '<path d="M3.2 6 10 10.6 16.8 6"/>'
    + '  </symbol>'
    + '  <symbol id="i-download" viewBox="0 0 20 20">'
    + '<path d="M10 3v8.4"/><path d="M6.4 8.4 10 12l3.6-3.6"/><path d="M3.6 14.6v1.2a1.2 1.2 0 0 0 1.2 1.2h10.4a1.2 1.2 0 0 0 1.2-1.2v-1.2"/>'
    + '  </symbol>'
    + '  <symbol id="i-exit" viewBox="0 0 20 20">'
    + '<path d="M12 3.4H5.6A1.6 1.6 0 0 0 4 5v10a1.6 1.6 0 0 0 1.6 1.6H12"/>'
    + '<path d="M13.4 6.8 16.6 10l-3.2 3.2"/><path d="M16.6 10H8.4"/>'
    + '  </symbol>'
    + '  <symbol id="i-chev" viewBox="0 0 20 20"><path d="m6.5 8.3 3.5 3.4 3.5-3.4"/></symbol>'
    + '</defs></svg>';

  var here = document.currentScript;
  if (here) here.insertAdjacentHTML("afterend", SPRITE);
  else document.body.insertAdjacentHTML("afterbegin", SPRITE);
})();
