import type {
	Attendee,
	LatestRaw,
	NotificationsManager,
	PresenceWithNotifications,
} from "@fluidframework/presence/alpha";
import {
	AttendeeStatus,
	Notifications,
	StateFactory,
} from "@fluidframework/presence/alpha";

const COLORS = [
	"#ff6b6b",
	"#f59e0b",
	"#14b8a6",
	"#38bdf8",
	"#818cf8",
	"#c084fc",
] as const;

export interface CursorPosition {
	/** Horizontal position from 0 (left) to 1 (right). */
	readonly x: number;
	/** Vertical position from 0 (top) to 1 (bottom). */
	readonly y: number;
}

/** Ephemeral state contributed independently by each connected attendee. */
export interface ParticipantState {
	readonly name: string;
	readonly color: string;
	readonly hasFocus: boolean;
	readonly cursor: CursorPosition;
}

export interface Participant {
	readonly attendee: Attendee;
	readonly attendeeId: string;
	readonly isLocal: boolean;
	readonly state: ParticipantState;
}

export interface Reaction {
	readonly attendee: Attendee;
	readonly emoji: string;
	readonly position: CursorPosition;
}

type ReactionNotifications = {
	reaction: (position: CursorPosition, emoji: string) => void;
};

type ChangeListener = () => void;
type ReactionListener = (reaction: Reaction) => void;

function hashString(value: string): number {
	let hash = 2166136261;
	for (const character of value) {
		hash ^= character.codePointAt(0) ?? 0;
		hash = Math.imul(hash, 16777619);
	}
	return hash >>> 0;
}

/** Produces a stable, human-friendly identity for one Presence attendee. */
export function createParticipantIdentity(attendeeId: string): {
	name: string;
	color: string;
} {
	const suffix = attendeeId
		.replace(/[^a-zA-Z0-9]/g, "")
		.slice(-4)
		.toUpperCase();
	const color = COLORS[hashString(attendeeId) % COLORS.length] ?? COLORS[0];
	return {
		name: `Guest ${suffix || "HERE"}`,
		color,
	};
}

/** Constrains a cursor coordinate to the normalized collaboration stage. */
export function normalizeCursor(position: CursorPosition): CursorPosition {
	const clamp = (value: number): number =>
		Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
	return { x: clamp(position.x), y: clamp(position.y) };
}

/**
 * Application-facing wrapper around Fluid Presence state and notifications.
 *
 * Presence values are intentionally ephemeral: no cursor, focus, or reaction
 * data is written to the SharedMap used to satisfy the container schema.
 */
export class PresenceTracker {
	private readonly participantState: LatestRaw<ParticipantState>;
	private readonly reactions: NotificationsManager<ReactionNotifications>;
	private readonly changeListeners = new Set<ChangeListener>();
	private readonly reactionListeners = new Set<ReactionListener>();
	private readonly cleanup: Array<() => void> = [];
	private disposed = false;

	public constructor(private readonly presence: PresenceWithNotifications) {
		const myself = presence.attendees.getMyself();
		const identity = createParticipantIdentity(myself.attendeeId);
		const initialState: ParticipantState = {
			...identity,
			hasFocus: true,
			cursor: { x: 0.5, y: 0.5 },
		};
		const stateWorkspace = presence.states.getWorkspace(
			"name:floodgate-presence-participants",
			{
				participant: StateFactory.latest<ParticipantState>({
					local: initialState,
				}),
			},
		);
		this.participantState = stateWorkspace.states.participant;

		const reactionWorkspace = presence.notifications.getWorkspace(
			"name:floodgate-presence-reactions",
			{
				reactions: Notifications<ReactionNotifications>({
					reaction: (attendee, position, emoji) => {
						if (!this.disposed) {
							this.emitReaction({
								attendee,
								emoji,
								position: normalizeCursor(position),
							});
						}
					},
				}),
			},
		);
		this.reactions = reactionWorkspace.notifications.reactions;

		this.cleanup.push(
			this.participantState.events.on("localUpdated", () => this.emitChanged()),
			this.participantState.events.on("remoteUpdated", () =>
				this.emitChanged(),
			),
			presence.attendees.events.on("attendeeConnected", () =>
				this.emitChanged(),
			),
			presence.attendees.events.on("attendeeDisconnected", () =>
				this.emitChanged(),
			),
		);
	}

	public getParticipants(): Participant[] {
		const myself = this.presence.attendees.getMyself();
		const participants: Participant[] = [
			{
				attendee: myself,
				attendeeId: myself.attendeeId,
				isLocal: true,
				state: this.participantState.local,
			},
		];

		for (const { attendee, value } of this.participantState.getRemotes()) {
			if (attendee.getConnectionStatus() === AttendeeStatus.Connected) {
				participants.push({
					attendee,
					attendeeId: attendee.attendeeId,
					isLocal: false,
					state: value,
				});
			}
		}
		return participants;
	}

	public getLocalState(): ParticipantState {
		return this.participantState.local;
	}

	public setCursor(position: CursorPosition): void {
		this.updateLocalState({ cursor: normalizeCursor(position) });
	}

	public setFocus(hasFocus: boolean): void {
		if (this.participantState.local.hasFocus !== hasFocus) {
			this.updateLocalState({ hasFocus });
		}
	}

	/** Controls how aggressively rapid cursor changes are coalesced. */
	public setCursorLatency(milliseconds: number): void {
		this.participantState.controls.allowableUpdateLatencyMs = Math.min(
			500,
			Math.max(0, milliseconds),
		);
	}

	public sendReaction(emoji: string): void {
		if (emoji.length === 0) {
			return;
		}
		const reaction: Reaction = {
			attendee: this.presence.attendees.getMyself(),
			emoji,
			position: this.participantState.local.cursor,
		};
		this.emitReaction(reaction);

		if (reaction.attendee.getConnectionStatus() === AttendeeStatus.Connected) {
			this.reactions.emit.broadcast(
				"reaction",
				reaction.position,
				reaction.emoji,
			);
		}
	}

	public subscribe(listener: ChangeListener): () => void {
		this.changeListeners.add(listener);
		return () => this.changeListeners.delete(listener);
	}

	public subscribeToReactions(listener: ReactionListener): () => void {
		this.reactionListeners.add(listener);
		return () => this.reactionListeners.delete(listener);
	}

	public dispose(): void {
		if (this.disposed) {
			return;
		}
		this.disposed = true;
		for (const removeListener of this.cleanup.splice(0)) {
			removeListener();
		}
		this.changeListeners.clear();
		this.reactionListeners.clear();
	}

	private updateLocalState(
		update: Partial<Pick<ParticipantState, "cursor" | "hasFocus">>,
	): void {
		this.participantState.local = {
			...this.participantState.local,
			...update,
		};
	}

	private emitChanged(): void {
		if (!this.disposed) {
			for (const listener of this.changeListeners) {
				listener();
			}
		}
	}

	private emitReaction(reaction: Reaction): void {
		for (const listener of this.reactionListeners) {
			listener(reaction);
		}
	}
}
