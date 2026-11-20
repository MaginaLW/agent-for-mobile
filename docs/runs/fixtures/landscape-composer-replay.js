// 只用于旁边的合成页。读取该页的已知颜色和具名控件，不能定位真实 App 输入栏。
if (params.has("replay")) {
  const results = [];
  const expect = (ok, label) => { if (!ok) throw Error(label); };

  function locate() {
    if (title.textContent !== "文件传输助手" ||
        ![title, canvas].includes(document.activeElement)) return null;
    // 只定位空白文本栏。已有发送控件或只有语音提示时，保留原态。
    if (send.getClientRects().length || voiceHint.getClientRects().length ||
        !voice.getClientRects().length || !more.getClientRects().length) return null;
    const bounds = canvas.getBoundingClientRect();
    const left = voice.getBoundingClientRect(), right = more.getBoundingClientRect();
    const keyboardTop = document.querySelector("aside").getBoundingClientRect().top;
    const top = Math.max(left.top, right.top, title.getBoundingClientRect().bottom);
    const bottom = Math.min(left.bottom, right.bottom, keyboardTop);
    if (bottom <= top || right.left <= left.right) return null;
    const y = Math.floor((top + bottom) / 2 - bounds.top);
    const pixels = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    const white = (x, line) => {
      const i = 4 * (line * canvas.width + x);
      return pixels[i] === 255 && pixels[i + 1] === 255 && pixels[i + 2] === 255;
    };
    const runs = [];
    const limit = Math.floor(right.left - bounds.left);
    for (let x = Math.ceil(left.right - bounds.left); x < limit;) {
      if (!white(x, y)) { x++; continue; }
      const begin = x;
      while (x < limit && white(x, y)) x++;
      runs.push([begin, x]);
    }
    if (runs.length !== 1) return null;
    const [x1, x2] = runs[0], middle = Math.floor((x1 + x2) / 2);
    let y1 = y, y2 = y + 1;
    while (y1 > 0 && white(middle, y1 - 1)) y1--;
    while (y2 < canvas.height && white(middle, y2)) y2++;
    if (bounds.top + y1 < top || bounds.top + y2 > bottom) return null;
    return {left: x1, right: x2, top: y1, bottom: y2};
  }

  function tryFocus() {
    const box = locate();
    if (box && document.activeElement !== canvas) {
      const bounds = canvas.getBoundingClientRect();
      const clientX = bounds.left + (box.left + box.right) / 2;
      const clientY = bounds.top + (box.top + box.bottom) / 2;
      document.elementFromPoint(clientX, clientY)
        .dispatchEvent(new MouseEvent("click", {bubbles: true, clientX, clientY}));
    }
    return box;
  }

  function prepare() {
    if (document.activeElement === row && row.textContent === "文件传输助手") row.click();
    return tryFocus();
  }

  function verify() {
    // 从左侧开始，即使右侧同名标题已经可见，仍不可点击编辑栏。
    row.focus();
    expect(tryFocus() === null && focusClicks === 0, "左侧焦点被误判为就位");
    main.classList.remove("open");
    layout = "single";
    draft = "";
    draw();
    expect(!send.getClientRects().length && more.getClientRects().length, "空稿右侧控件");
    const initialBox = {...field};
    const closed = prepare();
    // field 是渲染器的命中区域，只在断言中作为独立真值使用。
    expect(navigations === 1, "左侧会话导航次数");
    expect(closed && JSON.stringify(closed) === JSON.stringify(initialBox), "收起键盘时四边不符");
    expect(document.activeElement === canvas && focusClicks === 1, "点中空栏后未取得焦点");
    const open = prepare();
    expect(open && JSON.stringify(open) === JSON.stringify(field) &&
           open.bottom < closed.top && focusClicks === 1, "展开键盘后未重新定位或重复点击");
    expect(navigations === 1, "已就位时重复导航");
    results.push("左窗阻断、一次导航、一次聚焦、键盘移位后四边复核");

    // 直接从右窗开始。文本区域不唯一、缺失、或只见语音提示时不作选择。
    title.focus();
    main.classList.remove("open");
    for (const state of ["double", "missing", "voice"]) {
      layout = state;
      draw();
      if (state === "voice") {
        expect(voiceHint.getClientRects().length && !more.getClientRects().length &&
               !send.getClientRects().length, "语音态应只有转文字提示");
      }
      expect(prepare() === null && document.activeElement === title &&
             focusClicks === 1, state + " 错误聚焦");
    }
    layout = "single";
    draw();
    const name = title.textContent;
    title.textContent = "其他合成会话";
    expect(tryFocus() === null && focusClicks === 1, "会话标题不匹配时聚焦");
    title.textContent = name;
    expect(prepare() && navigations === 1 && focusClicks === 2 &&
           document.activeElement === canvas, "右窗起点应直接聚焦");
    expect(draft === "" && edits === 0 && sends === 0, "发生编辑或发送回调");
    results.push("空稿显示更多，右窗起点零导航，双框、缺框、语音态、异名会话均停止");
    title.focus();
    draft = "本地合成草稿"; // 用预置草稿覆盖可见发送按钮的场景。
    draw();
    expect(send.getClientRects().length && !more.getClientRects().length, "有稿右侧控件");
    expect(prepare() === null && document.activeElement === title &&
           focusClicks === 2 && draft === "本地合成草稿" && edits === 0 && sends === 0,
           "已有草稿被修改、聚焦或触发发送");
    results.push("有稿可见发送时保留原稿，全程编辑及发送回调为零");
  }

  const report = document.createElement("output");
  document.body.append(report);
  try {
    verify();
    report.dataset.replay = "PASS";
    report.textContent = results.join("；");
  } catch (error) {
    report.dataset.replay = "FAIL";
    report.textContent = error.message;
  }
}
