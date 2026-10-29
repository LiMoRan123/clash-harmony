import { http } from '@kit.NetworkKit';
import { DashboardServiceResult, DashboardServiceTarget } from '../models/HomeNetworkViewState';

export class NetworkProbeService {
  private requests: http.HttpRequest[] = [];

  static async exitIp(): Promise<string> {
    return new NetworkProbeService().readExitIp();
  }

  private createRequest(): http.HttpRequest {
    const request: http.HttpRequest = http.createHttp();
    this.requests.push(request);
    return request;
  }

  private release(request: http.HttpRequest): void {
    const index: number = this.requests.indexOf(request);
    if (index < 0) { return }
    this.requests.splice(index, 1);
    try { request.destroy() } catch (err) {}
  }

  cancel(): void {
    const requests: http.HttpRequest[] = this.requests;
    this.requests = [];
    for (const request of requests) {
      try { request.destroy() } catch (err) {}
    }
  }

  async readExitIp(): Promise<string> {
    const request: http.HttpRequest = this.createRequest();
    try {
      const response: http.HttpResponse = await request.request('https://api.ipify.org?format=json', {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
        connectTimeout: 5000, readTimeout: 5000, usingCache: false, maxLimit: 4096,
        usingProxy: { host: '127.0.0.1', port: 7890, exclusionList: [] }
      });
      if (response.responseCode !== 200) {
        throw new Error('出口 IP 检测失败，请稍后重试');
      }
      const payload = JSON.parse(response.result as string) as Record<string, Object>;
      const ip: Object = payload['ip'];
      if (typeof ip !== 'string' || !/^[0-9a-fA-F:.]+$/.test(ip) || ip.length > 45) {
        throw new Error('出口检测返回了无法识别的地址');
      }
      return ip;
    } finally {
      this.release(request);
    }
  }

  async measure(target: DashboardServiceTarget): Promise<DashboardServiceResult> {
    const began: number = Date.now();
    let request: http.HttpRequest | undefined;
    try {
      request = this.createRequest();
      const response: http.HttpResponse = await request.request(target.url, {
        method: http.RequestMethod.HEAD, expectDataType: http.HttpDataType.STRING,
        connectTimeout: 4000, readTimeout: 4000, usingCache: false, maxLimit: 16384,
        usingProxy: { host: '127.0.0.1', port: 7890, exclusionList: [] }
      });
      const code: number = response.responseCode;
      return { key: target.key, name: target.name,
        status: code >= 200 && code < 400 ? 'available' : 'restricted',
        delay: Math.max(1, Date.now() - began), code: code };
    } catch (err) {
      return { key: target.key, name: target.name, status: 'unreachable', delay: 0, code: 0 };
    } finally {
      if (request) { this.release(request) }
    }
  }
}
