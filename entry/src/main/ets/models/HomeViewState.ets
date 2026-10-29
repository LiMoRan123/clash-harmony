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
  downloadTotal: number = 0;
  uploadTotal: number = 0;
  downloadPeak: number = 0;
  uploadPeak: number = 0;

  recordTotals(download: number, upload: number, down: number, up: number): void {
    if (download < this.downloadTotal || upload < this.uploadTotal) {
      this.downloadPeak = 0;
      this.uploadPeak = 0;
    }
    this.downloadTotal = download;
    this.uploadTotal = upload;
    this.downloadPeak = Math.max(this.downloadPeak, down);
    this.uploadPeak = Math.max(this.uploadPeak, up);
  }

  reset(): void {
    this.downloadSpeed = '0 KB/s';
    this.uploadSpeed = '0 KB/s';
    this.connections = 0;
    this.uptime = '--:--:--';
    this.downloadTotal = 0;
    this.uploadTotal = 0;
    this.downloadPeak = 0;
    this.uploadPeak = 0;
    this.downloadHistory = this.downloadHistory.map(() => 0);
    this.uploadHistory = this.uploadHistory.map(() => 0);
  }
}
