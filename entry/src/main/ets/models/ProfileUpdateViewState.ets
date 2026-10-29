export interface ProfileUpdateFeedback {
  uid: string;
  ok: boolean;
  message: string;
}

@Observed
export class ProfileUpdateViewState {
  running: boolean = false;
  batch: boolean = false;
  activeUid: string = '';
  targetUids: string[] = [];
  completed: number = 0;
  succeeded: number = 0;
  failed: boolean = false;
  message: string = '';
  results: ProfileUpdateFeedback[] = [];

  begin(uids: string[], batch: boolean = false): boolean {
    if (this.running || uids.length === 0) { return false }
    this.targetUids = uids.slice();
    this.batch = batch;
    this.completed = 0;
    this.succeeded = 0;
    this.failed = false;
    this.results = [];
    this.message = '准备更新配置';
    this.activeUid = '';
    this.running = true;
    return true;
  }

  downloading(uid: string, name: string): void {
    this.activeUid = uid;
    this.message = '正在拉取并验证「' + name + '」';
  }

  complete(uid: string, ok: boolean, message: string): void {
    const results: ProfileUpdateFeedback[] = this.results.filter((item: ProfileUpdateFeedback) => item.uid !== uid);
    results.push({ uid: uid, ok: ok, message: message });
    this.results = results;
    if (this.activeUid === uid) { this.activeUid = '' }
    this.completed++;
    if (ok) { this.succeeded++ }
    else { this.failed = true }
  }

  finish(message: string): void {
    this.message = message;
    this.activeUid = '';
    this.running = false;
  }

  phaseFor(uid: string): string {
    if (this.running && this.targetUids.includes(uid)) {
      if (this.activeUid === uid) { return 'updating' }
      if (!this.results.some((item: ProfileUpdateFeedback) => item.uid === uid)) { return 'queued' }
    }
    const result: ProfileUpdateFeedback | undefined = this.results.find((item: ProfileUpdateFeedback) => item.uid === uid);
    return result ? result.ok ? 'success' : 'error' : 'idle';
  }

  messageFor(uid: string): string {
    const phase: string = this.phaseFor(uid);
    if (phase === 'updating') { return '正在下载并验证配置…' }
    if (phase === 'queued') { return '等待更新' }
    return this.results.find((item: ProfileUpdateFeedback) => item.uid === uid)?.message ?? '';
  }
}
