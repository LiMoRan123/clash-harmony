@Observed
export class ConnectionViewState {
  phase: string = 'idle';
  message: string = '未连接';
  busy: boolean = false;
  connected: boolean = false;
  profileName: string = '未选择配置';

  setPhase(phase: string, message: string): void {
    this.phase = phase;
    this.message = message;
    this.busy = ['preparing', 'creating', 'starting', 'verifying', 'stopping'].includes(phase);
  }
}

@Observed
export class TrafficViewState {
  downloadSpeed: string = '0 KB/s';
  uploadSpeed: string = '0 KB/s';
  connections: number = 0;
  uptime: string = '--:--:--';
  downloadHistory: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  uploadHistory: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
}
