## `InboxPlaybackOperator`: replays the operator's presses of a playback
## scenario (`sekOperator` entries) on an inbox viewmodel, so an inbox
## playback story shows what the operator did -- Next, Previous, an answer,
## auto-switch on or off -- through the same viewmodel calls a host's
## buttons make.
##
## The server keeps the inbox cursor, so where the operator is follows from
## these presses and the playback source's cursor, never from the scenario.
## An answer press answers the item on screen through its page
## (`InboxVM.page`; the inbox viewmodel needs `showPages`): a permission
## option by its id, otherwise the typed text. A press that cannot be made
## (no page, an answer the page refuses) is counted in `missed`.
##
## When the source starts over (a seek backwards), the operator puts the
## presses' own state back to the scenario's first moment -- auto-switch off
## -- before the source delivers the presses up to the target again, so a
## seek backwards shows what stepping there shows.

import ./data_source
import ./playback_source
import ./inbox_vm

export playback_source, inbox_vm

type
  InboxPlaybackOperator* = ref object
    source: PlaybackDataSource
    inbox: InboxVM
    presses: Subscription[OperatorPress]
    resets: Subscription[StreamReset]
    made*: int      ## presses made
    missed*: int    ## presses that could not be made

proc press*(op: InboxPlaybackOperator; p: OperatorPress): bool =
  ## Makes one press on the inbox; false when it could not be made.
  case p.kind
  of opNext: op.inbox.next()
  of opPrev: op.inbox.prev()
  of opAutoSwitch:
    op.inbox.setAutoSwitch(p.on)
    true
  of opAnswer:
    let page = op.inbox.page
    if page.isNil: return false
    if p.option.len > 0: return page.choosePermission(p.option)
    page.setText(p.text)
    page.submit()

proc newInboxPlaybackOperator*(source: PlaybackDataSource;
                               inbox: InboxVM): InboxPlaybackOperator =
  ## Follows `source`'s presses on `inbox` until `stop`.
  let op = InboxPlaybackOperator(source: source, inbox: inbox)
  op.presses = source.subscribePresses proc(answer: DataResult[OperatorPress]): ProgressDelivery =
    if not answer.ok: return pdUnchanged
    if op.press(answer.value):
      inc op.made
      pdApplied
    else:
      inc op.missed
      pdUnchanged
  op.resets = source.subscribeResets proc(answer: DataResult[StreamReset]): ProgressDelivery =
    op.inbox.setAutoSwitch(false)
    op.inbox.setTyping(false)
    pdApplied
  op

proc stop*(op: InboxPlaybackOperator) =
  ## Stops following the source's presses.
  op.presses.cancel()
  op.resets.cancel()
