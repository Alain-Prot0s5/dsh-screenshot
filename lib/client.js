// dsh-screenshot — client half.
// 1) 输入框右侧相机按钮（conversation.input.right）：点击请求本地 dsh-screenshot 监听器
//    触发服务（http://127.0.0.1:17890/trigger），截图并自动粘贴到输入框。
//    按钮不抢键盘焦点（onMouseDown preventDefault），保证粘贴落进文字框。
// 2) 设置页卡片（settings.plugin.item, key="dsh-screenshot"）：改快捷键 / 自动粘贴 /
//    后台跳转粘贴，通过 settingsScope 写入，宿主即时重启监听器生效。
window.__ModuleLoader__.load({
	// Must equal the package name: DSH Desktop >= 2.0.2 serves client bundles
	// under /plugins/<package-name>/client.js (the loader row `name`), so the
	// registration id has to be the full scoped package name.
	id: "@alain-prot0s5/dsh-screenshot",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		const react = require("react");
		const react_jsx_runtime = require("react/jsx-runtime");

		// 与监听器 $Config.TriggerPort 保持一致
		const TRIGGER_URL = "http://127.0.0.1:17890/trigger";
		const NS = "dsh-screenshot";

		const css = ".__dshSnipBtn{width:28px;height:28px;color:var(--dsw-alias-label-tertiary);cursor:pointer;background:transparent;border:none;border-radius:8px;display:inline-flex;align-items:center;justify-content:center;padding:5px;flex:none}.__dshSnipBtn:hover{background:var(--dsw-alias-interactive-bg-hover);color:var(--dsw-alias-label-secondary)}.__dshSnipBtn:disabled{cursor:default;opacity:.5}.__dshSnipBtn svg{width:16px;height:16px}.__dshSnipBtnError{color:var(--dsw-alias-danger,#e5484d)}.__dshSnipCard{border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-3);border-radius:10px;padding:14px 16px;gap:10px;display:flex;flex-direction:column}.__dshSnipCard h4{margin:0;font-size:14px;font-weight:600;color:var(--dsw-alias-label-primary)}.__dshSnipCard p{margin:0;color:var(--dsw-alias-label-tertiary);font-size:13px;line-height:20px}.__dshSnipCard .__dshSnipRow{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--dsw-alias-label-primary)}.__dshSnipCard label{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--dsw-alias-label-primary);cursor:pointer}.__dshSnipCard select{border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary);font:inherit;border-radius:6px;padding:3px 6px;font-size:13px}.__dshSnipCard input[type=checkbox]{accent-color:var(--dsw-alias-state-business-primary)}.__dshSnipHint{color:var(--dsw-alias-label-tertiary);font-size:12px;line-height:18px;margin:0}";
		const tagId = "dsh-screenshot/css";
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=\"" + tagId + "\"]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "dsh-screenshot";
			tag.dataset.pluginCss = tagId;
			tag.textContent = css;
			document.head.appendChild(tag);
		}

		// ---------- 输入框焦点守护 ----------
		// 记录最近聚焦过的"输入框样"元素（focusin 追踪），截图粘贴前恢复焦点用。
		const HEALTH_URL = "http://127.0.0.1:17890/health";
		const INPUT_SELECTOR = '[contenteditable="true"],[contenteditable="plaintext-only"],textarea,[role="textbox"],[data-slate-editor],.ProseMirror,.ql-editor';
		let lastInputLike = null;
		if (typeof document !== "undefined") {
			document.addEventListener("focusin", (e) => {
				const t = e.target;
				if (t && typeof t.matches === "function" && t.matches(INPUT_SELECTOR)) lastInputLike = t;
			}, true);
		}
		function focusComposerInput() {
			try {
				let el = lastInputLike;
				if (!el || !document.contains(el) || typeof el.focus !== "function") {
					el = document.querySelector(INPUT_SELECTOR);
				}
				if (el && document.contains(el) && typeof el.focus === "function" && el !== document.activeElement) {
					el.focus();
				}
			} catch { /* 忽略：焦点恢复失败不影响截图 */ }
		}
		// DSH 窗口重新获得焦点（截图遮罩关闭等）时，监听器可能正要自动粘贴——
		// 立即把焦点放回输入框，让 Ctrl+V 落对地方（纯客户端操作，不动鼠标）。
		if (typeof window !== "undefined") {
			window.addEventListener("focus", () => {
				const check = () => {
					fetch(HEALTH_URL, { method: "GET" })
						.then((res) => (res.ok ? res.json() : Promise.reject(new Error("http " + res.status))))
						.then((j) => { if (j && j.pending) focusComposerInput(); })
						.catch(() => {});
				};
				check();
				setTimeout(check, 250); // 防监听器 tick 竞态：再补查一次
			});
		}

		// ---------- 输入框截图按钮 ----------
		function SnipButton() {
			const [state, setState] = react.useState("idle"); // idle | busy | error
			const timer = react.useRef(null);
			const prevFocus = react.useRef(null);
			react.useEffect(() => () => {
				if (timer.current !== null) clearTimeout(timer.current);
			}, []);
			// 恢复输入框焦点：优先聚焦输入框（focusin 追踪/选择器兜底），
			// 输入框不可得时才回退到点击前的焦点元素。
			const restoreFocus = () => {
				focusComposerInput();
				try {
					const pf = prevFocus.current;
					const act = document.activeElement;
					if (pf && document.contains(pf) && typeof pf.focus === "function" &&
						(!act || typeof act.matches !== "function" || !act.matches(INPUT_SELECTOR))) {
						pf.focus();
					}
				} catch { /* 忽略 */ }
				prevFocus.current = null;
			};
			const onClick = () => {
				if (state === "busy") return;
				setState("busy");
				fetch(TRIGGER_URL, { method: "GET" })
					.then((res) => {
						if (!res.ok) throw new Error("http " + res.status);
						setState("idle");
					})
					.catch(() => {
						setState("error");
						if (timer.current !== null) clearTimeout(timer.current);
						timer.current = setTimeout(() => setState("idle"), 2500);
					});
				// 等 React 完成重渲染后再恢复焦点，确保几秒后的自动粘贴能落进输入框
				setTimeout(restoreFocus, 0);
			};
			return react_jsx_runtime.jsx("button", {
				type: "button",
				tabIndex: -1, // 按钮绝不参与焦点（配合 onMouseDown preventDefault 防抢焦点）
				className: "__dshSnipBtn" + (state === "error" ? " __dshSnipBtnError" : ""),
				title: state === "error" ? "截图服务未运行：请先启动 dsh-screenshot 监听器" : "截图并自动粘贴到输入框",
				"aria-label": "截图并自动粘贴到输入框",
				disabled: state === "busy",
				onMouseDown: (e) => {
					e.preventDefault();
					try { prevFocus.current = document.activeElement; } catch { prevFocus.current = null; }
				},
				onClick,
				children: state === "error"
					? react_jsx_runtime.jsx("span", { "aria-hidden": true, children: "!" })
					: react_jsx_runtime.jsx("svg", {
						viewBox: "0 0 16 16",
						fill: "none",
						stroke: "currentColor",
						"stroke-width": 1.4,
						"stroke-linecap": "round",
						"stroke-linejoin": "round",
						"aria-hidden": true,
						children: react_jsx_runtime.jsxs(react_jsx_runtime.Fragment, {
							children: [
								react_jsx_runtime.jsx("path", { d: "M2.5 5.2c0-.7.6-1.2 1.3-1.2h1.2l.8-1.2c.2-.3.5-.5.9-.5h3c.4 0 .7.2.9.5l.8 1.2h1.2c.7 0 1.3.5 1.3 1.2v6c0 .7-.6 1.3-1.3 1.3h-9c-.7 0-1.3-.6-1.3-1.3v-6z" }),
								react_jsx_runtime.jsx("circle", { cx: "8", cy: "8.3", r: "2.4" })
							]
						})
					})
			});
		}

		// ---------- 设置卡片 ----------
		const MODIFIER_OPTIONS = [
			["1", "Alt"],
			["2", "Ctrl"],
			["4", "Shift"],
			["8", "Win"],
			["3", "Ctrl+Alt"],
			["5", "Alt+Shift"],
			["6", "Ctrl+Shift"],
			["7", "Ctrl+Alt+Shift"]
		];
		const KEY_OPTIONS = (() => {
			const list = [];
			for (let code = 65; code <= 90; code++) list.push([String(code), String.fromCharCode(code)]);
			return list;
		})();

		function SnipSettingsCard({ scope }) {
			const [snap, setSnap] = react.useState(() => scope.getSnapshot());
			react.useEffect(() => scope.subscribe(() => setSnap(scope.getSnapshot())), [scope]);
			const value = snap?.value;
			if (snap?.status !== "ready" || value === void 0) {
				return react_jsx_runtime.jsx("section", { className: "__dshSnipCard", children: react_jsx_runtime.jsx("p", { children: "加载中…" }) });
			}
			const mod = value.hotkeyModifiers ?? 1;
			const vk = value.hotkeyVk ?? 65;
			const modLabel = (MODIFIER_OPTIONS.find(([m]) => Number(m) === mod) ?? ["", "?"])[1];
			const keyLabel = String.fromCharCode(vk);
			return react_jsx_runtime.jsxs("section", {
				className: "__dshSnipCard",
				children: [
					react_jsx_runtime.jsx("h4", { children: "截图自动粘贴（dsh-screenshot）" }),
					react_jsx_runtime.jsxs("div", {
						className: "__dshSnipRow",
						children: [
							react_jsx_runtime.jsx("span", { children: "全局快捷键" }),
							react_jsx_runtime.jsx("select", {
								value: String(mod),
								"aria-label": "修饰键",
								onChange: (e) => { scope.set("hotkeyModifiers", Number(e.target.value)); },
								children: MODIFIER_OPTIONS.map(([m, label]) => react_jsx_runtime.jsx("option", { value: m, children: label }, m))
							}),
							react_jsx_runtime.jsx("select", {
								value: String(vk),
								"aria-label": "键",
								onChange: (e) => { scope.set("hotkeyVk", Number(e.target.value)); },
								children: KEY_OPTIONS.map(([k, label]) => react_jsx_runtime.jsx("option", { value: k, children: label }, k))
							}),
							react_jsx_runtime.jsx("span", { children: "（当前 " + modLabel + "+" + keyLabel + "）" })
						]
					}),
					react_jsx_runtime.jsx("label", {
						children: [
							react_jsx_runtime.jsx("input", {
								type: "checkbox",
								checked: !!value.autoPaste,
								onChange: (e) => { scope.set("autoPaste", e.target.checked); }
							}),
							"截图后自动粘贴到输入框（关 = 只截图，图片留在剪贴板）"
						]
					}),
					react_jsx_runtime.jsx("label", {
						children: [
							react_jsx_runtime.jsx("input", {
								type: "checkbox",
								checked: !!value.switchWhenBackground,
								onChange: (e) => { scope.set("switchWhenBackground", e.target.checked); }
							}),
							"DSH 在后台时自动跳到前台并粘贴（关 = 后台仅截图，不切换窗口）"
						]
					}),
					react_jsx_runtime.jsx("p", { className: "__dshSnipHint", children: "设置即时生效（监听器会自动重启）；快捷键修改后按新组合键触发。" })
				]
			});
		}

		// ---------- 插件装配 ----------
		const inject = ["slots", "settingsScope", "connection", "remote"];

		function apply(ctx) {
			// 输入框截图按钮
			ctx.slots.inject("conversation.input.right", () => {
				const dispose = ctx.slots.register(
					{ name: "conversation.input.right", id: "dsh-screenshot", order: 100, label: "Screenshot" },
					SnipButton
				);
				return () => { dispose(); };
			});
			// 设置页卡片（命名空间 dsh-screenshot，由宿主注册）
			const scope = ctx.settingsScope.bind({ namespace: NS });
			ctx.slots.inject("settings.plugin.item", () => {
				const dispose = ctx.slots.register(
					{ name: "settings.plugin.item", key: NS },
					() => react_jsx_runtime.jsx(SnipSettingsCard, { scope })
				);
				return () => { dispose(); };
			});
		}

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
