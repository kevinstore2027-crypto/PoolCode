// Module id -> readable name.
//
// The hook stores a module as a uint8 that selects one branch of its fee arithmetic; the names below
// are the exact labels used by the deployed contract. MODULE_COUNT is fixed at four forever.
//
// Ids must match the constants in contracts/PoolCodeHook.sol:
//   MODULE_BASE = 0, MODULE_TIDE = 1, MODULE_CASCADE = 2, MODULE_BEACON = 3
export const MODULE_NAMES = {
  0: 'BASE',
  1: 'TIDE',
  2: 'CASCADE',
  3: 'BEACON',
};

/**
 * Resolve a module id to its label.
 *
 * An unknown id is still rendered defensively, although the deployed hook rejects every id >= 4.
 */
export function moduleName(id) {
  const key = Number(id);
  return MODULE_NAMES[key] ?? `Module ${key}`;
}
#kevinstore