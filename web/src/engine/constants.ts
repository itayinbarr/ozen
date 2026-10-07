/** Shared numbers. Must match tools/model/reference.py and the iOS OzenCore package. */

export const SR = 16000
export const N_FFT = 400
export const HOP = 160
export const N_MELS = 80
export const N_FREQ = N_FFT / 2 + 1 // 201
export const N_SAMPLES = 30 * SR // 480000
export const N_FRAMES = 3000
export const BOS = 1
export const EOS = 2
export const MAX_NEW_TOKENS = 220

/** Pinned model. Bumping the revision invalidates every cached copy. */
export const MODEL_REPO = 'itayinbar/Ozen-v1'
export const MODEL_REVISION = '82aae03decb5592029922ea15e19ed96d1e8ece3'

export interface ModelFile {
  key: 'encoder' | 'decoder' | 'tokenizer'
  path: string
  bytes: number
  sha256: string
}

export const MODEL_FILES: readonly ModelFile[] = [
  {
    key: 'encoder',
    path: 'onnx/encoder_model_fp16.onnx',
    bytes: 79134919,
    sha256: 'ec63a2dab9fe408baab3d7f16bf8316e7988c8982ba86f427354fb4a3b8b613b',
  },
  {
    key: 'decoder',
    path: 'onnx/decoder_model_merged.onnx',
    bytes: 85187076,
    sha256: 'e490fa4dd2f15b859ad5b7c94c3fdbe819262bebd18680a7742fed1ec863386b',
  },
  {
    key: 'tokenizer',
    path: 'tokenizer.json',
    bytes: 703265,
    sha256: '050f0aff338e5779ebe80f25c760da76857e009dc17c2caef8424d613ee7dbfa',
  },
]

export function modelUrl(path: string, revision = MODEL_REVISION): string {
  return `https://huggingface.co/${MODEL_REPO}/resolve/${revision}/${path}`
}
