import { DASHBOARD_SERVICES, DashboardServiceResult, HomeNetworkViewState } from '../models/HomeNetworkViewState';
import { NetworkProbeService } from './NetworkProbeService';

// One bounded batch per connection/route change, plus explicit user refresh.
// A generation guard prevents an old route from overwriting a newer session.
export class HomeNetworkMonitorService {
  private connected: boolean = false;
  private generation: number = 0;
  private client?: NetworkProbeService;

  connect(view: HomeNetworkViewState): void {
    if (this.connected) { return }
    this.connected = true;
    this.refresh(view);
  }

  disconnect(view: HomeNetworkViewState): void {
    if (!this.connected && !this.client) { return }
    this.connected = false;
    this.generation++;
    this.client?.cancel();
    this.client = undefined;
    view.reset();
  }

  async refresh(view: HomeNetworkViewState): Promise<void> {
    if (!this.connected || view.checkingExit || view.checkingServices) { return }
    const generation: number = ++this.generation;
    const client: NetworkProbeService = new NetworkProbeService();
    this.client = client;
    view.exitIp = '';
    view.exitMessage = '正在检测出口 IP…';
    view.checkingExit = true;
    view.checkingServices = true;
    view.services = view.services.map((item: DashboardServiceResult): DashboardServiceResult => {
      return { key: item.key, name: item.name, status: 'checking', delay: 0, code: 0 };
    });
    const current = (): boolean => this.connected && generation === this.generation;
    const exit = async (): Promise<void> => {
      try {
        const ip: string = await client.readExitIp();
        if (current()) { view.exitIp = ip; view.exitMessage = '出口 IP · 自动检测' }
      } catch (err) {
        if (current()) { view.exitMessage = '出口检测失败，可点击重试' }
      } finally {
        if (current()) { view.checkingExit = false }
      }
    };
    const worker = async (offset: number): Promise<void> => {
      for (let index = offset; index < DASHBOARD_SERVICES.length && current(); index += 2) {
        const result: DashboardServiceResult = await client.measure(DASHBOARD_SERVICES[index]);
        if (!current()) { return }
        view.services = view.services.map((item: DashboardServiceResult): DashboardServiceResult => {
          return item.key === result.key ? result : item;
        });
      }
    };
    try {
      await Promise.all([exit(), worker(0), worker(1)]);
    } finally {
      client.cancel();
      if (current()) {
        view.checkingExit = false;
        view.checkingServices = false;
        view.checkedAt = Date.now();
        this.client = undefined;
      }
    }
  }
}
