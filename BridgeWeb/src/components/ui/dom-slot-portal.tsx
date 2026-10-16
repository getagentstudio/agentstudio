import { useLayoutEffect, useState, type ReactNode, type ReactPortal, type RefObject } from 'react';
import { createPortal } from 'react-dom';

/** Resolve an owned slot after commit; an unattached slot never falls back to document.body. */
export function DomSlotPortal(props: {
	readonly container: RefObject<HTMLDivElement | null>;
	readonly children: ReactNode;
}): ReactPortal | null {
	const [attachedContainer, setAttachedContainer] = useState<HTMLDivElement | null>(() =>
		props.container.current?.isConnected === true ? props.container.current : null,
	);
	useLayoutEffect((): void => {
		const container = props.container.current;
		setAttachedContainer(container?.isConnected === true ? container : null);
	}, [props.container, props.children]);
	return attachedContainer?.isConnected === true
		? createPortal(props.children, attachedContainer)
		: null;
}
