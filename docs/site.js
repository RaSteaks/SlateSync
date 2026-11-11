// 支持页与隐私页共用的交互。页面本身是普通锚点和 details，这里只做增强；
// 除语言选择外不保存任何内容，表单文字只在访客点击后才交给 GitHub。
(function () {
  var root = document.documentElement;
  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  function isEnglish() { return root.dataset.lang === 'en'; }
  function t(zh, en) { return isEnglish() ? en : zh; }

  // 取元素在当前语言下实际可见的文字；另一语言的 span 只是被隐藏，textContent 仍会带上。
  function visibleTextNodes(element) {
    var hidden = isEnglish() ? '.lang-zh' : '.lang-en';
    var nodes = [];
    var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      if (!walker.currentNode.parentElement.closest(hidden)) { nodes.push(walker.currentNode); }
    }
    return nodes;
  }
  function visibleText(element) {
    return visibleTextNodes(element).map(function (node) { return node.data; }).join('').replace(/\s+/g, ' ').trim();
  }

  function copyText(text) {
    if (!navigator.clipboard) { return Promise.reject(new Error('clipboard unavailable')); }
    return navigator.clipboard.writeText(text);
  }

  /* ===== 语言切换：写入 <html data-lang> 与 lang，持久化到 localStorage ===== */
  var languageListeners = [];
  document.getElementById('langToggle').addEventListener('click', function () {
    var next = isEnglish() ? 'zh' : 'en';
    if (next === 'en') { root.dataset.lang = 'en'; root.lang = 'en'; } else { delete root.dataset.lang; root.lang = 'zh-Hans'; }
    try { localStorage.setItem('slatesync-support-lang', next); } catch (e) { /* 隐私模式下忽略 */ }
    languageListeners.forEach(function (listener) { listener(); });
  });

  /* ===== 图标页签：一次显示一个主题。链接仍是普通锚点，所以深链和前进后退照常工作 ===== */
  var tabLinks = [].slice.call(document.querySelectorAll('.tabs a'));
  var panels = [].slice.call(document.querySelectorAll('.panel'));

  function setPanel(panel) {
    panels.forEach(function (candidate) { candidate.classList.toggle('is-active', candidate === panel); });
    tabLinks.forEach(function (link) {
      if (link.dataset.panel === panel.id) { link.setAttribute('aria-current', 'true'); } else { link.removeAttribute('aria-current'); }
    });
  }

  function activePanel() { return document.querySelector('.panel.is-active'); }

  // 从被点击的页签位置揭示内容区，对应应用里「页签从内容上缘对应控件位置的投影揭示」。
  function revealPanel(panel, tab) {
    var supported = document.startViewTransition && !reduceMotion.matches;
    if (!supported || panel === activePanel()) { setPanel(panel); return; }
    var box = tab.getBoundingClientRect();
    root.style.setProperty('--reveal-x', (box.left + box.width / 2) + 'px');
    document.startViewTransition(function () { setPanel(panel); });
  }

  // 页签吸顶后切换主题要回到内容开头；页头还在视野内时不滚动，避免页面无故跳动。
  function scrollToPanelStart() {
    var tabs = document.querySelector('.tabs');
    var stage = document.querySelector('.stage');
    var offset = stage.getBoundingClientRect().top - tabs.getBoundingClientRect().bottom;
    if (offset < 0) { window.scrollBy({ top: offset, behavior: 'auto' }); }
  }

  tabLinks.forEach(function (link) {
    link.addEventListener('click', function (event) {
      if (event.metaKey || event.ctrlKey || event.shiftKey) { return; }
      event.preventDefault();
      revealPanel(document.getElementById(link.dataset.panel), link);
      history.pushState(null, '', link.getAttribute('href'));
      scrollToPanelStart();
    });
  });

  /* ===== 定位：切到目标所在主题，打开它所在的 details，滚到它并短暂标出位置 ===== */
  function showBlock(element) {
    var panel = element.closest('.panel');
    if (panel) { setPanel(panel); }
    var host = element.closest('details');
    if (host) { host.open = true; }
  }

  function locate(element) {
    showBlock(element);
    element.scrollIntoView({ block: 'center', behavior: reduceMotion.matches ? 'auto' : 'smooth' });
    element.classList.remove('is-located');
    void element.offsetWidth; // 重新触发动画，连续点同一结果时也有反馈
    element.classList.add('is-located');
  }

  var reportSheet = document.getElementById('report-sheet');

  // 根据 hash 决定显示内容：#faq 切主题，#q-account 打开答案，#report 打开反馈 sheet。
  function followHash() {
    var id = window.location.hash.slice(1);
    if (id === 'report' && reportSheet) { openReport(); return; }
    var target = id ? document.getElementById(id) : null;
    if (target && panels.length) {
      showBlock(target);
      if (target.matches('details')) { target.open = true; }
      target.scrollIntoView();
    } else if (panels.length && !id) {
      setPanel(panels[0]);
    }
  }

  /* ===== 条款目录：隐私页标记当前阅读的条款，窄屏横条把当前项保持在视野内 ===== */
  var tocBar = document.querySelector('.toc');
  if (tocBar) {
    var links = [].slice.call(tocBar.querySelectorAll('a'));
    var sections = links.map(function (link) { return document.querySelector(link.getAttribute('href')); });
    var frame = 0;
    var currentIndex = -1;
    var markCurrent = function () {
      frame = 0;
      var readingLine = window.innerHeight * 0.35;
      var current = -1;
      sections.forEach(function (section, index) {
        if (section.getBoundingClientRect().top <= readingLine) { current = index; }
      });
      if (window.innerHeight + window.scrollY >= root.scrollHeight - 2) { current = sections.length - 1; }
      if (current === currentIndex) { return; }
      currentIndex = current;
      links.forEach(function (link, index) {
        if (index === current) { link.setAttribute('aria-current', 'location'); } else { link.removeAttribute('aria-current'); }
      });
      if (current >= 0 && tocBar.scrollWidth > tocBar.clientWidth) {
        tocBar.scrollTo({
          left: links[current].offsetLeft - (tocBar.clientWidth - links[current].offsetWidth) / 2,
          behavior: reduceMotion.matches ? 'auto' : 'smooth'
        });
      }
    };
    var schedule = function () { if (!frame) { frame = window.requestAnimationFrame(markCurrent); } };
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    markCurrent();
  }

  /* ===== 工具栏搜索：按当前语言检索全部内容（含未显示的主题），结果浮在搜索框下 ===== */
  var searchInput = document.getElementById('site-search');
  var searchBox = document.querySelector('.search');
  var blockSelector = 'details, .card, .steps li, ul.plain li, .summary li, .section-sub, .clause-body > p, .note, tbody tr, .flow-box';
  var maxResults = 30;

  var searchClear = document.querySelector('.search-clear');
  var resultsBox = document.querySelector('.search-results');
  var resultsCount = document.querySelector('.search-count');
  var resultsList = document.querySelector('.search-results ol');
  var resultsEmpty = document.querySelector('.search-empty');

  var blocks = [].slice.call(document.querySelector('main').querySelectorAll(blockSelector)).filter(function (block) {
    return !block.parentElement.closest(blockSelector); // 嵌套时只保留最外层，避免同一段出现两次
  });

  function blockTitle(block) {
    var heading = block.querySelector('summary, h3, b');
    if (heading) { return visibleText(heading); }
    var section = block.closest('section');
    return section ? visibleText(section.querySelector('h2')) : '';
  }

  // 摘要去掉与标题重复的开头；FAQ 的问题本身已经显示在结果标题上。
  function snippet(text, title, term) {
    if (text.indexOf(title) === 0 && text.length > title.length) { text = text.slice(title.length).trim(); }
    var at = text.toLowerCase().indexOf(term);
    if (at <= 18) { return text.slice(0, 72); }
    return '…' + text.slice(at - 18, at + 54);
  }

  function highlight(terms, matches) {
    if (!window.Highlight || !window.CSS || !CSS.highlights) { return; }
    var ranges = [];
    matches.forEach(function (block) {
      visibleTextNodes(block).forEach(function (node) {
        var text = node.data.toLowerCase();
        terms.forEach(function (term) {
          for (var at = text.indexOf(term); at !== -1; at = text.indexOf(term, at + term.length)) {
            var range = new Range();
            range.setStart(node, at);
            range.setEnd(node, at + term.length);
            ranges.push(range);
          }
        });
      });
    });
    CSS.highlights.set('search-hit', new Highlight(...ranges));
  }

  function closeResults() { resultsBox.hidden = true; }

  function runSearch() {
    var terms = searchInput.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    searchInput.placeholder = t('搜索本页', 'Search this page');
    searchClear.hidden = !searchInput.value;
    resultsBox.hidden = !terms.length;
    resultsList.textContent = '';

    if (!terms.length) { highlight([], []); return; }

    var matches = blocks.filter(function (block) {
      var text = visibleText(block).toLowerCase();
      return terms.every(function (term) { return text.indexOf(term) !== -1; });
    });
    highlight(terms, matches);

    resultsCount.textContent = t(matches.length + ' 个结果', matches.length + (matches.length === 1 ? ' result' : ' results'));
    resultsEmpty.hidden = matches.length > 0;

    matches.slice(0, maxResults).forEach(function (block) {
      var item = document.createElement('li');
      var link = document.createElement('a');
      var title = document.createElement('b');
      var detail = document.createElement('small');
      link.href = '#';
      title.textContent = blockTitle(block);
      detail.textContent = snippet(visibleText(block), title.textContent, terms[0]);
      link.append(title, detail);
      link.addEventListener('click', function (event) {
        event.preventDefault();
        closeResults();
        locate(block);
      });
      item.append(link);
      resultsList.append(item);
    });
  }

  function clearSearch() {
    searchInput.value = '';
    runSearch();
  }

  searchInput.addEventListener('input', runSearch);
  searchInput.addEventListener('focus', function () { if (searchInput.value.trim()) { runSearch(); } });
  searchInput.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') { clearSearch(); searchInput.blur(); }
    if (event.key === 'Enter') {
      event.preventDefault();
      var first = resultsList.querySelector('a');
      if (first) { first.click(); }
    }
    if (event.key === 'ArrowDown') {
      var top = resultsList.querySelector('a');
      if (top) { event.preventDefault(); top.focus(); }
    }
  });
  resultsBox.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') { closeResults(); searchInput.focus(); return; }
    var item = event.target.closest('li');
    if (!item || (event.key !== 'ArrowDown' && event.key !== 'ArrowUp')) { return; }
    event.preventDefault();
    var next = event.key === 'ArrowDown' ? item.nextElementSibling : item.previousElementSibling;
    if (next) { next.querySelector('a').focus(); } else if (event.key === 'ArrowUp') { searchInput.focus(); }
  });
  searchClear.addEventListener('click', function () { clearSearch(); searchInput.focus(); });
  // 浮层只在搜索区内停留；点到页面其他地方就收起，保留已输入的文字。
  document.addEventListener('pointerdown', function (event) {
    if (!searchBox.contains(event.target)) { closeResults(); }
  });
  window.addEventListener('keydown', function (event) {
    var typing = event.target.closest && event.target.closest('input, textarea, select, [contenteditable]');
    if (event.key === '/' && !typing && !event.metaKey && !event.ctrlKey && !event.altKey && !(reportSheet && reportSheet.open)) {
      event.preventDefault();
      searchInput.focus();
    }
  });
  languageListeners.push(function () {
    runSearch();
    if (document.activeElement !== searchInput) { closeResults(); }
  });

  /* ===== 数据流向：穿出设备边界的线第一次进入视野时画出 ===== */
  var flowExit = document.querySelector('.flow-exit');
  if (flowExit && window.IntersectionObserver) {
    var flowObserver = new IntersectionObserver(function (entries) {
      if (!entries[0].isIntersecting) { return; }
      flowExit.classList.add('is-shown');
      flowObserver.disconnect();
    }, { threshold: 0.6 });
    flowObserver.observe(flowExit);
  } else if (flowExit) {
    flowExit.classList.add('is-shown');
  }

  /* ===== 问题反馈 sheet：拼出预填好的 GitHub Issue，由访客自己确认提交 ===== */
  // GitHub 对过长的预填链接会直接报错；超出时改走剪贴板。
  var issueUrlLimit = 6000;
  var report = document.querySelector('.report');
  var issueInput = document.getElementById('r-issue');

  function openReport(prefill) {
    if (prefill && !issueInput.value) { issueInput.value = prefill; }
    closeResults();
    if (!reportSheet.open) { reportSheet.showModal(); }
    issueInput.focus();
  }

  if (report) {
    var issueBase = report.dataset.issues;
    var issueError = document.getElementById('r-issue-error');
    var status = report.querySelector('.report-status');
    var groups = [].slice.call(report.querySelectorAll('[data-for]'));
    var fields = [].slice.call(report.querySelectorAll('.field'));

    var checkedFeature = function () { return report.querySelector('[data-report-feature] input:checked'); };

    var showGroups = function () {
      var feature = checkedFeature();
      var chosen = feature ? feature.dataset.group : '';
      groups.forEach(function (group) { group.hidden = group.dataset.for !== chosen; });
    };

    var validated = function () {
      var valid = Boolean(issueInput.value.trim());
      issueError.hidden = valid;
      if (valid) {
        issueInput.removeAttribute('aria-invalid');
      } else {
        issueInput.setAttribute('aria-invalid', 'true');
        issueInput.focus();
      }
      return valid;
    };

    // 标签取当前语言的可见文字，所以 Issue 用的语言和访客正在读的一致。
    var compose = function () {
      return fields.filter(function (field) { return !field.closest('[hidden]'); }).map(function (field) {
        var checked = field.querySelector('input:checked + span');
        var entry = field.querySelector('input[type="text"], textarea');
        var value = checked ? visibleText(checked) : (entry ? entry.value.trim() : '');
        return value ? '**' + visibleText(field.querySelector('.field-label')) + '**\n\n' + value : '';
      }).filter(Boolean).join('\n\n');
    };

    var title = function () {
      var feature = checkedFeature();
      var summary = issueInput.value.trim();
      return feature ? visibleText(feature.nextElementSibling) + ': ' + summary : summary;
    };

    var issueUrl = function (withBody) {
      return issueBase + '?title=' + encodeURIComponent(title()) + (withBody ? '&body=' + encodeURIComponent(compose()) : '');
    };

    report.addEventListener('change', showGroups);
    issueInput.addEventListener('input', function () {
      if (issueInput.value.trim()) { issueError.hidden = true; issueInput.removeAttribute('aria-invalid'); }
    });

    report.addEventListener('submit', function (event) {
      event.preventDefault();
      if (!validated()) { return; }
      var full = issueUrl(true);
      if (full.length <= issueUrlLimit) {
        window.open(full, '_blank', 'noopener');
        status.textContent = t('已在新标签页打开 GitHub，确认后再提交。', 'GitHub opened in a new tab. Review it before submitting.');
        return;
      }
      // 先开窗口：放到异步回调之后，弹窗会被浏览器拦截。
      window.open(issueUrl(false), '_blank', 'noopener');
      copyText(compose()).then(function () {
        status.textContent = t('内容较长，已复制到剪贴板，请粘贴到 Issue 正文。', 'That is too long for a link, so it was copied. Paste it into the issue body.');
      }, function () {
        status.textContent = t('内容较长且无法写入剪贴板，请缩短后重试。', 'That is too long for a link and the clipboard is unavailable. Shorten it and try again.');
      });
    });

    report.querySelector('[data-report-copy]').addEventListener('click', function () {
      if (!validated()) { return; }
      copyText(title() + '\n\n' + compose()).then(function () {
        status.textContent = t('已复制。', 'Copied.');
      }, function () {
        status.textContent = t('无法写入剪贴板，请手动选择内容。', 'The clipboard is unavailable. Select the text manually.');
      });
    });

    // 取消只收起 sheet，已填内容留到本页关闭，误触不会丢。
    report.querySelector('[data-report-cancel]').addEventListener('click', function () { reportSheet.close(); });

    // 关闭时去掉 #report，否则之后刷新或后退会再次弹出。
    reportSheet.addEventListener('close', function () {
      if (window.location.hash === '#report') { history.replaceState(null, '', window.location.pathname + window.location.search); }
    });

    [].slice.call(document.querySelectorAll('[data-report-open]')).forEach(function (button) {
      button.addEventListener('click', function () { openReport(); });
    });

    // 搜不到时，把搜索词带进反馈表单作为问题描述。
    document.querySelector('[data-carry-query]').addEventListener('click', function () {
      openReport(searchInput.value.trim());
    });

    showGroups();
  }

  searchInput.value = new URLSearchParams(window.location.search).get('q') || '';
  runSearch();
  if (panels.length) { setPanel(panels[0]); }
  followHash();
  window.addEventListener('hashchange', followHash);
  window.addEventListener('popstate', followHash);
})();
