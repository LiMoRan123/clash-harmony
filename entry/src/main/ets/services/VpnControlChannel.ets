import { commonEventManager } from '@kit.BasicServicesKit';

const BUNDLE: string = 'io.github.clashharmony.app';
const EVENT: string = BUNDLE + '.VPN_CONTROL';

interface VpnCommand {
  action: string;
  sessionId: string;
}

export class VpnControlChannel {
  private subscriber?: commonEventManager.CommonEventSubscriber;
  private generation: number = 0;

  static send(action: string, sessionId: string): void {
    try {
      const command: VpnCommand = { action: action, sessionId: sessionId };
      commonEventManager.publish(EVENT, { bundleName: BUNDLE, data: JSON.stringify(command) }, () => {});
    } catch (err) {}
  }

  async subscribe(onCommand: (action: string, sessionId: string) => void): Promise<void> {
    const generation: number = this.generation;
    const subscriber = await commonEventManager.createSubscriber({ events: [EVENT], publisherBundleName: BUNDLE });
    if (generation !== this.generation) { commonEventManager.unsubscribe(subscriber); return }
    this.subscriber = subscriber;
    commonEventManager.subscribe(subscriber, (err, data) => {
      if (err || !data.data || data.data.length > 512 || generation !== this.generation) { return }
      try {
        const command: VpnCommand = JSON.parse(data.data) as VpnCommand;
        if (!command || !['stop', 'status'].includes(command.action) || typeof command.sessionId !== 'string' ||
          command.sessionId.length > 128 || (command.action === 'stop' && command.sessionId.length === 0)) { return }
        onCommand(command.action, command.sessionId);
      } catch (error) {}
    });
  }

  close(): void {
    this.generation++;
    const subscriber = this.subscriber;
    this.subscriber = undefined;
    if (subscriber) { try { commonEventManager.unsubscribe(subscriber) } catch (err) {} }
  }
}
