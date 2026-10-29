import { http } from '@kit.NetworkKit';

export class NetworkProbeService {
  static async exitIp(): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request('https://api.ipify.org?format=json', {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
        connectTimeout: 5000, readTimeout: 5000, usingCache: false,
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
      request.destroy();
    }
  }
}
