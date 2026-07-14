import { useEffect, useRef, useState } from "react";

import type {
	Participant,
	PresenceTracker,
	Reaction,
} from "./presenceTracker.js";
import "./style.css";

const EMOJIS = ["❤️", "👏", "🎉", "✨", "👋"] as const;

interface VisibleReaction extends Reaction {
	readonly id: number;
}

export interface PresenceAppViewProps {
	tracker: PresenceTracker;
	documentId: string;
	shareUrl?: string;
	onCreateNew?: () => void;
}

function initials(name: string): string {
	return name
		.split(" ")
		.map((part) => part[0])
		.join("")
		.slice(0, 2)
		.toUpperCase();
}

function ParticipantCard({
	participant,
}: {
	participant: Participant;
}): React.ReactElement {
	return (
		<li className="presence-person">
			<span
				className="presence-avatar"
				style={{ backgroundColor: participant.state.color }}
				aria-hidden="true"
			>
				{initials(participant.state.name)}
			</span>
			<span className="presence-person-copy">
				<strong>
					{participant.state.name}
					{participant.isLocal ? " (you)" : ""}
				</strong>
				<small>{participant.state.hasFocus ? "Active now" : "Tab away"}</small>
			</span>
			<span
				className={
					participant.state.hasFocus ? "presence-dot is-active" : "presence-dot"
				}
				title={participant.state.hasFocus ? "Active" : "Away"}
			/>
		</li>
	);
}

/** Responsive, accessible visualization of collaborative Presence state. */
export function PresenceAppView({
	tracker,
	documentId,
	shareUrl,
	onCreateNew,
}: PresenceAppViewProps): React.ReactElement {
	const [participants, setParticipants] = useState(() =>
		tracker.getParticipants(),
	);
	const [selectedEmoji, setSelectedEmoji] =
		useState<(typeof EMOJIS)[number]>("❤️");
	const [latency, setLatency] = useState(60);
	const [copied, setCopied] = useState(false);
	const [reactions, setReactions] = useState<VisibleReaction[]>([]);
	const reactionId = useRef(0);
	const reactionTimers = useRef<ReturnType<typeof setTimeout>[]>([]);

	useEffect(() => {
		const refresh = (): void => setParticipants(tracker.getParticipants());
		const unsubscribe = tracker.subscribe(refresh);
		const unsubscribeReactions = tracker.subscribeToReactions((reaction) => {
			const id = reactionId.current++;
			setReactions((current) => [...current, { ...reaction, id }]);
			const timer = setTimeout(() => {
				setReactions((current) => current.filter((item) => item.id !== id));
			}, 1400);
			reactionTimers.current.push(timer);
		});

		const updateFocus = (): void => tracker.setFocus(document.hasFocus());
		window.addEventListener("focus", updateFocus);
		window.addEventListener("blur", updateFocus);
		updateFocus();

		return () => {
			unsubscribe();
			unsubscribeReactions();
			window.removeEventListener("focus", updateFocus);
			window.removeEventListener("blur", updateFocus);
			for (const timer of reactionTimers.current) {
				clearTimeout(timer);
			}
		};
	}, [tracker]);

	const remoteParticipants = participants.filter(
		(participant) => !participant.isLocal,
	);

	const handlePointerMove = (
		event: React.PointerEvent<HTMLDivElement>,
	): void => {
		const bounds = event.currentTarget.getBoundingClientRect();
		tracker.setCursor({
			x: (event.clientX - bounds.left) / bounds.width,
			y: (event.clientY - bounds.top) / bounds.height,
		});
	};

	const copyShareLink = async (): Promise<void> => {
		const value = shareUrl ?? window.location.href;
		await navigator.clipboard.writeText(value);
		setCopied(true);
		window.setTimeout(() => setCopied(false), 1800);
	};

	return (
		<main className="presence-shell">
			<header className="presence-header">
				<div>
					<span className="presence-eyebrow">
						<span className="presence-live-dot" /> Live with Floodgate
					</span>
					<h1>Presence playground</h1>
					<p>Move, react, and watch every active session come alive.</p>
				</div>
				<div className="presence-header-actions">
					<button
						type="button"
						className="presence-button"
						onClick={() => void copyShareLink()}
					>
						{copied ? "Link copied" : "Copy invite link"}
					</button>
					{onCreateNew ? (
						<button
							type="button"
							className="presence-button is-secondary"
							onClick={onCreateNew}
						>
							New room
						</button>
					) : null}
				</div>
			</header>

			<section className="presence-grid">
				<div
					className="presence-stage"
					onPointerMove={handlePointerMove}
					onPointerDown={(event) => {
						handlePointerMove(event);
						tracker.sendReaction(selectedEmoji);
					}}
					role="application"
					aria-label="Shared cursor and reaction stage"
				>
					<div className="presence-stage-copy">
						<span>Shared canvas</span>
						<strong>Move your pointer</strong>
						<small>Click anywhere to send {selectedEmoji}</small>
					</div>

					{remoteParticipants.map((participant) => (
						<div
							className={
								participant.state.hasFocus
									? "presence-cursor"
									: "presence-cursor is-away"
							}
							key={participant.attendeeId}
							style={{
								color: participant.state.color,
								left: `${participant.state.cursor.x * 100}%`,
								top: `${participant.state.cursor.y * 100}%`,
							}}
						>
							<svg viewBox="0 0 24 28" aria-hidden="true" focusable="false">
								<path d="M2 2l18 10-8 2-4 9z" />
							</svg>
							<span style={{ backgroundColor: participant.state.color }}>
								{participant.state.name}
							</span>
						</div>
					))}

					{reactions.map((reaction) => (
						<span
							className="presence-reaction"
							key={reaction.id}
							style={{
								left: `${reaction.position.x * 100}%`,
								top: `${reaction.position.y * 100}%`,
							}}
							aria-hidden="true"
						>
							{reaction.emoji}
						</span>
					))}
				</div>

				<aside className="presence-sidebar">
					<section className="presence-card">
						<div className="presence-card-heading">
							<div>
								<span className="presence-kicker">In this room</span>
								<h2>Participants</h2>
							</div>
							<span className="presence-count">{participants.length}</span>
						</div>
						<ul className="presence-people" aria-live="polite">
							{participants.map((participant) => (
								<ParticipantCard
									key={participant.attendeeId}
									participant={participant}
								/>
							))}
						</ul>
					</section>

					<section className="presence-card">
						<span className="presence-kicker">Quick reaction</span>
						<h2>Make some noise</h2>
						<fieldset className="presence-emoji-row">
							<legend>Choose a reaction</legend>
							{EMOJIS.map((emoji) => (
								<button
									type="button"
									key={emoji}
									className={emoji === selectedEmoji ? "is-selected" : ""}
									aria-pressed={emoji === selectedEmoji}
									onClick={() => setSelectedEmoji(emoji)}
								>
									{emoji}
								</button>
							))}
						</fieldset>
					</section>

					<section className="presence-card">
						<label className="presence-range-label" htmlFor="cursor-latency">
							<span>
								<span className="presence-kicker">Broadcast tuning</span>
								<strong>Cursor latency</strong>
							</span>
							<output>{latency} ms</output>
						</label>
						<input
							id="cursor-latency"
							type="range"
							min="0"
							max="200"
							step="10"
							value={latency}
							onChange={(event) => {
								const value = event.currentTarget.valueAsNumber;
								setLatency(value);
								tracker.setCursorLatency(value);
							}}
						/>
						<p>
							Higher values coalesce rapid updates and reduce network traffic.
						</p>
					</section>
				</aside>
			</section>

			<footer className="presence-footer">
				<span>Room</span>
				<code title={documentId}>{documentId}</code>
				<span>Presence is ephemeral and is never stored in the document.</span>
			</footer>
		</main>
	);
}
