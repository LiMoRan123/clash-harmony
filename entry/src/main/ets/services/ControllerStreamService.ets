import { webSocket } from '@kit.NetworkKit';

export class ControllerStreamService {
  private socket?: webSocket.WebSocket;
  private timer: number = -1;
  private connectTimer: number = -1;
  private generation: number = 0;
  private attempts: number = 0;
  private active: boolean = false;
  private onData?: (raw: string) => void;
  private onUnavailable?: () => void;

  start(onData: (raw: string) => void, onUnavailable: () => void): void {
    this.onData = onData;
    this.onUnavailable = onUnavailable;
    if (this.active) { return }
    this.active = true;
    this.attempts = 0;
    this.open(this.generation);
  }

  private open(generation: number): void {
    if (!this.active || generation !== this.generation) { return }
    let socket: webSocket.WebSocket;
    try {
      socket = webSocket.createWebSocket();
    } catch (err) {
      this.active = false;
      this.onUnavailable?.();
      return;
    }
    this.socket = socket;
    let failed: boolean = false;
    const reconnect = (): void => {
      if (failed || !this.active || generation !== this.generation || this.socket !== socket) { return }
      failed = true;
      clearTimeout(this.connectTimer);
      this.connectTimer = -1;
      this.socket = undefined;
      try { socket.close().catch(() => {}); } catch (err) {}
      this.attempts++;
      if (this.attempts > 3) {
        this.active = false;
        this.onUnavailable?.();
        return;
      }
      this.timer = setTimeout(() => { this.open(generation) }, 500 * this.attempts);
    };
    socket.on('message', (err, data) => {
      if (err || failed || !this.active || generation !== this.generation || this.socket !== socket) { return }
      if (typeof data === 'string') {
        this.attempts = 0;
        this.onData?.(data);
      }
    });
    socket.on('close', () => { reconnect() });
    socket.on('error', () => { reconnect() });
    this.connectTimer = setTimeout(() => { reconnect() }, 5000);
    try {
      socket.connect('ws://127.0.0.1:9090/connections?interval=1000').then((ok: boolean) => {
        if (generation !== this.generation || !this.active || this.socket !== socket) {
          socket.close().catch(() => {});
          return;
        }
        clearTimeout(this.connectTimer);
        this.connectTimer = -1;
        if (!ok) { reconnect() }
      }).catch(() => { reconnect() });
    } catch (err) { reconnect() }
  }

  stop(): void {
    this.active = false;
    this.generation++;
    clearTimeout(this.timer);
    clearTimeout(this.connectTimer);
    this.timer = -1;
    this.connectTimer = -1;
    const socket = this.socket;
    this.socket = undefined;
    if (socket) {
      try { socket.close().catch(() => {}); } catch (err) {}
    }
  }
}
