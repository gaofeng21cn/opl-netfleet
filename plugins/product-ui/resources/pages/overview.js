/* SPDX-License-Identifier: Apache-2.0 */
import { mountPage } from '../entry.js';

export async function mount(context) {
  return mountPage(context, 'overview');
}
