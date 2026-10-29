import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

// Separate files avoid UI/extension writers overwriting each other. Only known
// lifecycle messages and numeric error codes belong here, never configuration.
export class RuntimeDiagnostics {
  static append(context: common.Context, source: string, message: string): void {
    let file: fileIo.File | undefined;
    try {
      const path: string = context.filesDir + '/runtime-' + source + '.log';
      let previous: string = '';
      try { previous = fileIo.readTextSync(path) } catch (err) {}
      const lines: string[] = previous.split('\n').filter((line: string) => line.length > 0).slice(-39);
      lines.push(new Date().toISOString() + ' [' + source + '] ' + message);
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, lines.join('\n') + '\n');
    } catch (err) {
      // Diagnostic storage must never interrupt tunnel cleanup.
    } finally {
      if (file) { try { fileIo.closeSync(file) } catch (err) {} }
    }
  }

  static read(context: common.Context): string[] {
    const lines: string[] = [];
    for (const source of ['ui', 'vpn']) {
      try {
        const text: string = fileIo.readTextSync(context.filesDir + '/runtime-' + source + '.log');
        lines.push(...text.split('\n').filter((line: string) => line.length > 0));
      } catch (err) {}
    }
    return lines.sort().slice(-80);
  }
}
