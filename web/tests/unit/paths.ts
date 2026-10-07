import { resolve } from 'node:path'

export const SPEC = resolve(import.meta.dirname, '../../../spec')
export const MODEL_DIR = process.env.OZEN_MODEL_DIR ?? resolve(process.env.HOME ?? '', '.cache/ozen/models/82aae03d')
