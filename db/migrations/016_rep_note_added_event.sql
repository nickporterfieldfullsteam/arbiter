-- Migration 016: add rep_note_added to sent_notifications event_type CHECK
-- ================================================================

alter table sent_notifications drop constraint if exists sent_notifications_event_type_check;
alter table sent_notifications add constraint sent_notifications_event_type_check
  check (event_type in ('new_submission', 'project_updated', 'member_invited', 'rep_note_added'));
