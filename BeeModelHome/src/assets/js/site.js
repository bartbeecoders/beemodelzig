/* BeeModel website: small, no framework. */
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];

  // theme: remembered, else the system's
  const root = document.documentElement;
  try {
    const t = localStorage.getItem('bm-theme');
    if (t) root.dataset.theme = t;
  } catch (e) { /* private mode */ }
  $$('.theme-toggle').forEach(b => b.addEventListener('click', () => {
    const dark = root.dataset.theme
      ? root.dataset.theme === 'dark'
      : matchMedia('(prefers-color-scheme: dark)').matches;
    root.dataset.theme = dark ? 'light' : 'dark';
    try { localStorage.setItem('bm-theme', root.dataset.theme); } catch (e) { /* ignore */ }
  }));

  // mobile menu
  const toggle = $('.nav-toggle'), links = $('.nav-links');
  if (toggle && links) {
    toggle.addEventListener('click', () => {
      const open = links.classList.toggle('open');
      toggle.setAttribute('aria-expanded', open);
    });
    $$('a', links).forEach(a => a.addEventListener('click', () => links.classList.remove('open')));
  }

  // reveal on scroll, counters, videos playing while seen
  const io = new IntersectionObserver(entries => {
    for (const e of entries) {
      const el = e.target;
      if (el.tagName === 'VIDEO') {
        if (e.isIntersecting) el.play().catch(() => {}); else el.pause();
        continue;
      }
      if (!e.isIntersecting) continue;
      el.classList.add('in');
      if (el.dataset.count) count(el);
      io.unobserve(el);
    }
  }, { threshold: 0.18 });
  if (location.search.includes('static')) {                         // (whole-page captures)
    $$('.reveal').forEach(el => el.classList.add('in'));
    $$('[data-count]').forEach(el => { el.firstChild.nodeValue = el.dataset.count; delete el.dataset.count; });
  }
  $$('.reveal, [data-count]').forEach(el => io.observe(el));
  $$('video[data-autoplay]').forEach(v => io.observe(v));

  function count(el) {
    const target = parseFloat(el.dataset.count), dec = (el.dataset.count.split('.')[1] || '').length;
    const t0 = performance.now(), dur = 1400;
    const step = now => {
      const k = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - k, 3);
      el.firstChild.nodeValue = (target * e).toFixed(dec);
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  // lightbox for screenshots and renders
  const lb = document.createElement('div');
  lb.className = 'lightbox';
  lb.innerHTML = '<img alt=""><div class="cap"></div>';
  document.body.appendChild(lb);
  const open = (src, cap) => {
    $('img', lb).src = src;
    $('.cap', lb).textContent = cap || '';
    lb.classList.add('open');
  };
  lb.addEventListener('click', () => lb.classList.remove('open'));
  document.addEventListener('keydown', e => { if (e.key === 'Escape') lb.classList.remove('open'); });
  $$('[data-full]').forEach(el => el.addEventListener('click', () => open(el.dataset.full, el.dataset.caption)));

  // the feature tour: tabs swap the spotlight shown
  $$('.tour').forEach(tour => {
    const tabs = $$('.tour-tabs button', tour), panes = $$('.tour-pane', tour);
    const show = i => {
      tabs.forEach((t, j) => t.setAttribute('aria-selected', i === j));
      panes.forEach((p, j) => { p.hidden = i !== j; });
    };
    tabs.forEach((t, i) => t.addEventListener('click', () => show(i)));
    show(0);
  });

  // copy buttons
  $$('.copy').forEach(b => b.addEventListener('click', () => {
    const pre = b.parentElement.querySelector('pre');
    navigator.clipboard.writeText(pre.dataset.copy || pre.innerText).then(() => {
      b.textContent = 'Copied';
      setTimeout(() => { b.textContent = 'Copy'; }, 1600);
    });
  }));

  // the latest release, live from GitHub (the page has what it was built with;
  // before the first release this finds nothing and the source links stay)
  const fmt = n => n < 4096 ? n + ' bytes' : n > 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.round(n / 1024) + ' KB';
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  if ($('[data-latest]')) {
    fetch('https://api.github.com/repos/bartbeecoders/beemodelzig/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
      .then(r => r.ok ? r.json() : null)
      .then(rel => {
        if (!rel || !rel.tag_name || !rel.assets || !rel.assets.length) return;
        const v = rel.tag_name.replace(/^v/, '');
        const date = new Date(rel.published_at).toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' });
        $$('[data-latest="version"]').forEach(el => { el.textContent = v; });
        $$('[data-latest="badge"]').forEach(el => { el.innerHTML = `Latest <b>v${esc(v)}</b> · ${esc(date)}`; });
        $$('[data-latest="status"]').forEach(el => {
          el.innerHTML = `Released ${esc(date)} · <a href="${esc(rel.html_url)}">release notes</a> · <a href="releases.html">all releases</a>`;
        });
        const kind = n => /SHA256/.test(n) ? 'SHA256' : /gpu/.test(n) ? 'GPU' : n.endsWith('.zip') ? 'ZIP' : n.endsWith('.tar.gz') ? 'TAR.GZ' : 'BIN';
        $$('[data-latest="files"]').forEach(el => {
          el.innerHTML = '<div class="dl-files">' + rel.assets.map(a =>
            `<a class="dl-file" href="${esc(a.browser_download_url)}"><span class="ext">${kind(a.name)}</span>` +
            `<span class="name">${esc(a.name)}</span><span class="size">${fmt(a.size)}</span></a>`).join('') + '</div>';
        });
      })
      .catch(() => { /* offline: the built-in links stay */ });
  }

  // releases page: filter as you type
  const filter = $('#rel-filter');
  if (filter) {
    filter.addEventListener('input', () => {
      const q = filter.value.trim().toLowerCase();
      $$('.release').forEach(r => { r.hidden = q && !r.textContent.toLowerCase().includes(q); });
    });
  }

  // the hero's honeycomb: drawn once, a slow shimmer
  const hex = $('.hex-bg');
  if (hex && hex.getContext) {
    const ctx = hex.getContext('2d');
    const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
    let cells = [], w = 0, h = 0;
    const size = 26, dx = size * Math.sqrt(3), dy = size * 1.5;
    const resize = () => {
      const r = hex.getBoundingClientRect(), dpr = Math.min(2, devicePixelRatio || 1);
      w = r.width; h = r.height; hex.width = w * dpr; hex.height = h * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      cells = [];
      for (let y = 0, row = 0; y < h + size; y += dy, row++)
        for (let x = (row % 2) * dx / 2; x < w + dx; x += dx) cells.push([x, y, Math.random() * 6.28]);
    };
    const draw = t => {
      ctx.clearRect(0, 0, w, h);
      for (const [x, y, p] of cells) {
        const a = 0.05 + 0.12 * Math.max(0, Math.sin(t / 1600 + p + x / 300));
        ctx.strokeStyle = `rgba(245,166,35,${a})`;
        ctx.beginPath();
        for (let i = 0; i < 6; i++) {
          const ang = Math.PI / 3 * i + Math.PI / 6;
          ctx.lineTo(x + Math.cos(ang) * (size - 3), y + Math.sin(ang) * (size - 3));
        }
        ctx.closePath(); ctx.stroke();
      }
      if (!reduce) requestAnimationFrame(draw);
    };
    resize(); addEventListener('resize', resize); requestAnimationFrame(draw);
  }
})();
