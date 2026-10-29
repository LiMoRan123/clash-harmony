import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';

export class DocumentExportService {
  static async save(context: common.Context, name: string, content: string): Promise<boolean> {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.save({ newFileNames: [name] });
    if (uris.length === 0) {
      return false;
    }
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      await fileIo.write(file.fd, content);
      return true;
    } finally {
      if (file) {
        fileIo.closeSync(file);
      }
    }
  }
}
