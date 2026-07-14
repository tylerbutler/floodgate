/**
 * Floodgate Presence demo package exports.
 *
 * @packageDocumentation
 */

export {
	buildTokenEndpoint,
	DEV_ONLY_MINT_CREDENTIAL,
	type FloodgatePresenceConfig,
	type ResolvedConfig,
	resolveConfig,
} from "./config.js";
export { type MountConfig, mount } from "./mount.js";
export {
	type CursorPosition,
	createParticipantIdentity,
	normalizeCursor,
	type Participant,
	type ParticipantState,
	PresenceTracker,
	type Reaction,
} from "./presenceTracker.js";
export {
	createPresenceSession,
	type PresenceContainerSchema,
	type PresenceSession,
	presenceContainerSchema,
} from "./session.js";
