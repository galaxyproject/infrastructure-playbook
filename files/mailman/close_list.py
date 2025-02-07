# run with:
#   mailman withlist -r close_list -l <listspec> [public|private|nochange]
from mailman.interfaces.action import Action
from mailman.interfaces.archiver import ArchivePolicy
from mailman.interfaces.mailinglist import SubscriptionPolicy
from mailman.model.roster import RosterVisibility


ATTRS = (
    "advertised",
    "member_roster_visibility",
    "respond_to_post_requests",
    "send_welcome_message",
    "send_goodbye_message",
    "admin_immed_notify",
    "digests_enabled",
    "digest_send_periodic",
    "default_member_action",
    "default_nonmember_action",
    "subscription_policy",
    "unsubscription_policy",
    "archive_policy",
)


def _collect(m, d):
    for attr in ATTRS:
        d[attr] = getattr(m, attr)


def _compare(m, d):
    for attr in ATTRS:
        if d[attr] != getattr(m, attr):
            print(f"{attr}: {d[attr]} -> {getattr(m, attr)}")


def close_list(m, archive='nochange'):
    old_settings = {}
    _collect(m, old_settings)

    m.advertised = False
    m.member_roster_visibility = RosterVisibility.moderators
    m.respond_to_post_requests = False
    m.send_welcome_message = False
    m.send_goodbye_message = False
    m.admin_immed_notify = False
    m.digests_enabled = False
    m.digest_send_periodic = False
    m.default_member_action = Action.discard
    m.default_nonmember_action = Action.discard
    # there is currently not an option for "disable" so this is the best we can do
    m.subscription_policy = SubscriptionPolicy.confirm_then_moderate
    m.unsubscription_policy = SubscriptionPolicy.confirm
    if archive == 'public':
        m.archive_policy = ArchivePolicy.public
    elif archive == 'private':
        m.archive_policy = ArchivePolicy.private
    elif archive != 'nochange':
        raise Exception(f"Unknown archive option: {archive}")

    _compare(m, old_settings)
