const { spawn } = require('node:child_process');
const { createInterface } = require('node:readline');
const { createGateway, findLanAddress } = require('./lan-gateway.cjs');

const [distro, runtime, host, portArg = '8767', backendArg = '8766'] = process.argv.slice(2);
const port = Number(portArg);
const backendPort = Number(backendArg);
const subnet = findLanAddress(host)?.cidr;
const isPort = (value) => Number.isInteger(value) && value >= 1 && value <= 65535;

if (!distro || !runtime || !subnet || !isPort(port) || !isPort(backendPort) || port === backendPort) {
  console.error('用法：node pc-narration.cjs <WSL 发行版> <合成程序目录> <电脑局域网 IP> [访问端口] [合成端口]');
  process.exit(1);
}

// Windows can close a console before its processes finish handling a signal.
// The Linux worker also stops if the Windows parent stops sending input.
const supervise = `
exec 3<&0
nice -n 10 bash ./run.sh serve.py --port "$1" --provider cuda --cuda-sampler-and-codec --no-spin </dev/null 3<&- &
server=$!
(
  while IFS= read -r -t 8 line <&3; do :; done
  kill "$server" 2>/dev/null || true
) &
guard=$!
cleanup() {
  kill "$server" "$guard" 2>/dev/null || true
  wait "$server" "$guard" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
wait "$server"
`;

process.title = '清阅电脑合成';
console.log('正在启动清阅电脑合成，请稍候。关闭此窗口即可停止服务。');

const gateway = createGateway(backendPort, subnet);
gateway.prependListener('request', (request, response) => {
  if (request.method !== 'POST' || request.url !== '/synthesize') return;
  const startedAt = performance.now();
  const time = new Date().toLocaleTimeString('zh-CN', { hour12: false });
  console.log(`[${time}] 收到音频合成请求。`);
  response.once('finish', () => {
    const seconds = ((performance.now() - startedAt) / 1000).toFixed(2);
    if (response.statusCode !== 200) {
      console.log(`[${time}] 请求失败（HTTP ${response.statusCode}），总用时 ${seconds} 秒。`);
      return;
    }
    const synthesis = Number(response.getHeader('x-synthesis-seconds'));
    const duration = Number(response.getHeader('x-audio-seconds'));
    const details = Number.isFinite(synthesis) && Number.isFinite(duration)
      ? `合成 ${synthesis.toFixed(2)} 秒，音频 ${duration.toFixed(2)} 秒，` : '';
    console.log(`[${time}] 已发送音频，${details}总用时 ${seconds} 秒。`);
  });
  response.once('close', () => {
    if (!response.writableFinished) console.log(`[${time}] 请求已断开。`);
  });
});

const worker = spawn('wsl.exe', [
  '-d', distro, '--cd', runtime, '--exec', 'bash', '-c', supervise, 'qingyue', String(backendPort),
], { windowsHide: true, stdio: ['pipe', 'pipe', 'inherit'] });

let stopping = false;
let started = false;
const sendHeartbeat = () => {
  if (worker.stdin.writable) worker.stdin.write('\n');
};
const heartbeat = setInterval(sendHeartbeat, 1000);
worker.stdin.on('error', () => {});
sendHeartbeat();

function stop(code) {
  if (stopping) return;
  stopping = true;
  process.exitCode = code;
  clearInterval(heartbeat);
  worker.stdin.end();
  gateway.close();
  gateway.closeAllConnections();
}

function fail(message) {
  if (stopping) return;
  console.error(message);
  stop(1);
}

gateway.on('error', (error) => fail(`无法监听 ${host}:${port}（${error.code}）。`));
worker.on('error', (error) => fail(`无法启动 WSL 合成程序（${error.message}）。`));
worker.on('exit', (code) => fail(`合成程序已退出（${code ?? '停止信号'}）。`));

createInterface({ input: worker.stdout }).on('line', (line) => {
  if (stopping) return;
  if (!line.startsWith('Qingyue TTS ready on ')) {
    console.log(line);
  } else if (!started) {
    started = true;
    gateway.listen(port, host, () => console.log(`已就绪。清阅里填写 ${host}:${port}`));
  }
});

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => stop(0));
