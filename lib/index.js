// dsh-screenshot — host half: screenshot-to-input for DSH Desktop.
//   - 把 dsh-screenshot 监听器脚本绑定到 DSH Desktop 生命周期（启动拉起 / 关闭停止）
//   - 注册 "dsh-screenshot" 设置命名空间（快捷键 / 自动粘贴 / 后台跳转），变更即时重启监听器生效
//
// 客户端（lib/client.js）提供输入框按钮 + 设置卡片；按钮走本地 HTTP 触发服务（17890）。
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import z from "@deepseek-ai/schemastery";

export const name = "dsh-screenshot";
// "settings" 服务用 ctx.inject 可选注入（见 apply），不作为插件必需服务，
// 部署中不存在时设置页不可用，但监听器仍按默认配置启动
export const inject = [];
export const Config = z.object({
	// 热键：修饰键（1=Alt 2=Ctrl 4=Shift 8=Win，可相加）+ 键码（65='A'）
	hotkeyModifiers: z.natural().min(0).max(15).default(1),
	hotkeyVk: z.natural().min(48).max(222).default(65),
	// 截图后自动粘贴到输入框（false = 只截图）
	autoPaste: z.boolean().default(true),
	// DSH 在后台时也跳到前台并粘贴（false = 后台仅截图，不切换窗口）
	switchWhenBackground: z.boolean().default(false)
});

const NS = "dsh-screenshot";
const PS1_PATH = fileURLToPath(new URL("../dsh-screenshot.ps1", import.meta.url));

function killStaleListeners(onDone) {
	// 清掉残留的监听器实例（上次强制结束应用留下的 / 手动启动的），
	// 确保本次启动拿到干净的互斥锁与端口。
	const ps = [
		"Get-CimInstance Win32_Process |",
		"Where-Object { $_.Name -match 'powershell|pwsh' -and $_.CommandLine -like '*dsh-screenshot.ps1*' } |",
		"ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
	].join(" ");
	try {
		const killer = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps], {
			stdio: "ignore",
			windowsHide: true
		});
		killer.on("error", () => { });
		killer.on("exit", () => { if (typeof onDone === "function") onDone(); });
		setTimeout(() => { if (typeof onDone === "function") onDone(); }, 3000).unref?.();
	} catch {
		if (typeof onDone === "function") onDone();
	}
}

/** 把设置值翻译成监听器启动参数（未修改的设置不传，用脚本默认）。 */
function listenerArgs(cfg) {
	const args = [
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", PS1_PATH,
		"-ExitWhenDshGone"
	];
	if (cfg.hotkeyModifiers !== 1) args.push("-HotkeyModifiers", String(cfg.hotkeyModifiers));
	if (cfg.hotkeyVk !== 65) args.push("-HotkeyVk", String(cfg.hotkeyVk));
	if (cfg.autoPaste === false) args.push("-NoAutoPaste");
	if (cfg.switchWhenBackground === true) args.push("-SwitchWhenBackground");
	return args;
}

function spawnListener(ctx, cfg) {
	const child = spawn("powershell.exe", listenerArgs(cfg), { stdio: "ignore", windowsHide: true });
	child.on("error", (error) => {
		ctx.logger?.warn?.("[dsh-screenshot] 启动监听器失败:", error?.message ?? String(error));
	});
	return child;
}

export function apply(ctx, config) {
	let child = null;
	let restartTimer = null;
	const stop = () => {
		if (restartTimer !== null) { clearTimeout(restartTimer); restartTimer = null; }
		if (child) { try { child.kill(); } catch { /* ignore */ } child = null; }
	};
	// 启动/重启监听器（先清残留再拉起）
	const start = (cfg) => {
		stop();
		killStaleListeners(() => {
			try {
				child = spawnListener(ctx, cfg);
				ctx.logger?.info?.("[dsh-screenshot] 监听器已启动", JSON.stringify(cfg));
			} catch (error) {
				ctx.logger?.warn?.("[dsh-screenshot] 启动监听器异常:", error?.message ?? String(error));
			}
		});
	};

	// 1) 始终先按当前配置拉起监听器（settings 服务不可用也不影响功能）
	start(config);

	// 2) 注册设置命名空间；变更（用户改设置页）→ 去抖后重启监听器即时生效
	ctx.inject(["settings"], (sctx) => {
		let scope;
		try {
			scope = sctx.settings.register(NS, Config, { base: config });
		} catch (error) {
			ctx.logger?.warn?.("[dsh-screenshot] 设置注册失败:", error?.message ?? String(error));
			return;
		}
		const unwatch = scope.watch(() => {
			const resolved = scope.get();
			if (restartTimer !== null) clearTimeout(restartTimer);
			restartTimer = setTimeout(() => start(resolved), 400);
		});
		sctx.effect(() => () => {
			try { unwatch(); } catch { /* ignore */ }
		}, "dsh-screenshot: settings watch");
	});

	// 3) DSH 关闭：停止监听器（看门狗兜底硬杀场景）
	ctx.effect(() => () => {
		stop();
		ctx.logger?.info?.("[dsh-screenshot] DSH 关闭，监听器已停止");
	}, "dsh-screenshot: listener lifecycle");
}
