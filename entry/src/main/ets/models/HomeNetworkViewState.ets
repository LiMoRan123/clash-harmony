export interface DashboardServiceTarget {
  key: string;
  name: string;
  url: string;
}

export interface DashboardServiceResult {
  key: string;
  name: string;
  status: string;
  delay: number;
  code: number;
}

export const DASHBOARD_SERVICES: DashboardServiceTarget[] = [
  { key: 'google', name: 'Google', url: 'https://www.google.com/generate_204' },
  { key: 'github', name: 'GitHub', url: 'https://github.com' },
  { key: 'youtube', name: 'YouTube', url: 'https://www.youtube.com/generate_204' },
  { key: 'chatgpt', name: 'ChatGPT', url: 'https://chatgpt.com' }
];

@Observed
export class HomeNetworkViewState {
  exitIp: string = '';
  exitMessage: string = '连接后自动检测出口 IP';
  checkingExit: boolean = false;
  checkingServices: boolean = false;
  checkedAt: number = 0;
  services: DashboardServiceResult[] = [];

  constructor() {
    this.reset();
  }

  reset(): void {
    this.exitIp = '';
    this.exitMessage = '连接后自动检测出口 IP';
    this.checkingExit = false;
    this.checkingServices = false;
    this.checkedAt = 0;
    this.services = DASHBOARD_SERVICES.map((target: DashboardServiceTarget): DashboardServiceResult => {
      return { key: target.key, name: target.name, status: 'idle', delay: 0, code: 0 };
    });
  }

  summary(): string {
    if (this.checkingServices) { return '正在检测' }
    if (this.checkedAt === 0) { return '连接后自动检测' }
    const available: number = this.services.filter((item: DashboardServiceResult) => item.status === 'available').length;
    return available === this.services.length ? '全部可达' : `${available} / ${this.services.length} 可达`;
  }
}
