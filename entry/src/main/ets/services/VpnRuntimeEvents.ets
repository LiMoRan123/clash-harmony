import { commonEventManager } from '@kit.BasicServicesKit';

const BUNDLE: string = 'io.github.clashharmony.app';
const EVENT: string = BUNDLE + '.VPN_RUNTIME';
const PHASES: string[] = ['creating', 'starting', 'verifying', 'connected', 'stopping', 'disconnected', 'error'];

export interface VpnRuntimeEvent {
  sessionId: string;
  sequence: number;
  phase: string;
  elapsedMs: number;
  version: string;
}

interface RuntimeWaiter {
  sessionId: string;
  phases: string[];
  resolve: (event: VpnRuntimeEvent | undefined) => void;
  timer: number;
}

export class VpnRuntimeEvents {
  private static subscriber?: commonEventManager.CommonEventSubscriber;
  private static listener?: (event: VpnRuntimeEvent) => void;
  private static latest?: VpnRuntimeEvent;
  private static waiters: RuntimeWaiter[] = [];
  private static generation: number = 0;

  static parse(text: string): VpnRuntimeEvent | undefined {
    try {
      if (text.length > 4096) { return undefined }
      const event: VpnRuntimeEvent = JSON.parse(text) as VpnRuntimeEvent;
      if (!event || typeof event.sessionId !== 'string' || event.sessionId.length === 0 ||
        event.sessionId.length > 128 || !Number.isSafeInteger(event.sequence) || event.sequence < 1 ||
        !PHASES.includes(event.phase) || !Number.isFinite(event.elapsedMs) || event.elapsedMs < 0 ||
        typeof event.version !== 'string' || event.version.length > 128) { return undefined }
      return event;
    } catch (err) { return undefined }
  }

  static publish(event: VpnRuntimeEvent): void {
    // Only this application receives the packet; subscription also restricts
    // the publisher. No config path, subscription or credentials are included.
    try {
      commonEventManager.publish(EVENT, { bundleName: BUNDLE, data: JSON.stringify(event) }, () => {});
    } catch (err) {}
  }

  static async subscribe(listener: (event: VpnRuntimeEvent) => void): Promise<boolean> {
    VpnRuntimeEvents.listener = listener;
    if (VpnRuntimeEvents.subscriber) { return true }
    const generation: number = VpnRuntimeEvents.generation;
    try {
      const subscriber = await commonEventManager.createSubscriber({
        events: [EVENT], publisherBundleName: BUNDLE
      });
      if (generation !== VpnRuntimeEvents.generation) {
        commonEventManager.unsubscribe(subscriber);
        return false;
      }
      VpnRuntimeEvents.subscriber = subscriber;
      commonEventManager.subscribe(subscriber, (err, data) => {
        if (generation !== VpnRuntimeEvents.generation || VpnRuntimeEvents.subscriber !== subscriber) { return }
        if (err || !data.data) { return }
        const event: VpnRuntimeEvent | undefined = VpnRuntimeEvents.parse(data.data);
        if (!event) { return }
        const latest = VpnRuntimeEvents.latest;
        if (latest && latest.sessionId === event.sessionId && latest.sequence >= event.sequence) { return }
        VpnRuntimeEvents.latest = event;
        try { VpnRuntimeEvents.listener?.(event); } catch (listenerError) {}
        const remaining: RuntimeWaiter[] = [];
        for (const waiter of VpnRuntimeEvents.waiters) {
          if (waiter.sessionId === event.sessionId && waiter.phases.includes(event.phase)) {
            clearTimeout(waiter.timer);
            waiter.resolve(event);
          } else { remaining.push(waiter) }
        }
        VpnRuntimeEvents.waiters = remaining;
      });
      return true;
    } catch (err) { return false }
  }

  static waitFor(sessionId: string, phases: string[], timeoutMs: number): Promise<VpnRuntimeEvent | undefined> {
    const latest = VpnRuntimeEvents.latest;
    if (latest && latest.sessionId === sessionId && phases.includes(latest.phase)) {
      return Promise.resolve(latest);
    }
    return new Promise<VpnRuntimeEvent | undefined>((resolve) => {
      const waiter: RuntimeWaiter = { sessionId: sessionId, phases: phases, resolve: resolve, timer: -1 };
      waiter.timer = setTimeout(() => {
        VpnRuntimeEvents.waiters = VpnRuntimeEvents.waiters.filter((item: RuntimeWaiter) => item !== waiter);
        resolve(undefined);
      }, timeoutMs);
      VpnRuntimeEvents.waiters.push(waiter);
    });
  }

  static unsubscribe(): void {
    VpnRuntimeEvents.generation++;
    VpnRuntimeEvents.listener = undefined;
    const subscriber = VpnRuntimeEvents.subscriber;
    VpnRuntimeEvents.subscriber = undefined;
    if (subscriber) {
      try { commonEventManager.unsubscribe(subscriber); } catch (err) {}
    }
    for (const waiter of VpnRuntimeEvents.waiters) {
      clearTimeout(waiter.timer);
      waiter.resolve(undefined);
    }
    VpnRuntimeEvents.waiters = [];
  }
}
