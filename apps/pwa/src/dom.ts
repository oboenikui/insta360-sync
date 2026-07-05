type ElementProps = {
  className?: string;
  textContent?: string;
  hidden?: boolean;
  id?: string;
};

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props?: ElementProps,
  ...children: (Node | string)[]
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (props?.className) node.className = props.className;
  if (props?.textContent !== undefined) node.textContent = props.textContent;
  if (props?.hidden) node.hidden = true;
  if (props?.id) node.id = props.id;
  for (const child of children) {
    node.append(child instanceof Node ? child : document.createTextNode(child));
  }
  return node;
}

export function replaceChildren(parent: Element, ...children: Node[]) {
  parent.replaceChildren(...children);
}

export function appendDefinitionList(
  parent: Element,
  entries: Array<{ term: string; value: string; valueClassName?: string }>
) {
  const dl = el("dl", { className: "cert-info" });
  for (const { term, value, valueClassName } of entries) {
    dl.append(el("dt", { textContent: term }));
    dl.append(el("dd", { className: valueClassName, textContent: value }));
  }
  replaceChildren(parent, dl);
}

export function appendMutedMessage(parent: Element, message: string) {
  replaceChildren(parent, el("p", { className: "muted", textContent: message }));
}
