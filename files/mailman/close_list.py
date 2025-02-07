# run with:
#   mailman withlist -r close_list -l <listspec> [public|private|nochange]
from mailman.app.moderator import handle_message
from mailman.interfaces.action import Action
from mailman.interfaces.archiver import ArchivePolicy
from mailman.interfaces.mailinglist import SubscriptionPolicy
from mailman.interfaces.requests import IListRequests, RequestType
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


class Colors:
    yellow = '\033[0;33m'
    purple = '\033[0;35m'
    rset = '\033[0m'


def _fmt(s, color=Colors.purple):
    return color + s + Colors.rset


def _collect(m, d):
    for attr in ATTRS:
        d[attr] = getattr(m, attr)


def _compare(m, d):
    msg = _fmt("List settings changes:")
    for attr in ATTRS:
        if d[attr] != getattr(m, attr):
            if msg:
                print(msg)
                msg = None
            print(f"{attr}: {d[attr]} -> {getattr(m, attr)}")
    if msg:
        print(_fmt("No list settings changes"))


def _mod_queue(m, request_type):
    requestdb = IListRequests(m)
    if not requestdb.count_of(request_type):
        print(_fmt(f"No pending {request_type.name} requests!"))
        return
    request_ids = []
    for request in requestdb.of_type(request_type):
        if not request_ids:
            print(_fmt(f"Pending {request_type.name} requests:"))
        request_ids.append(request.id)
        key, data = requestdb.get_request(request.id, request_type)
        if request_type == RequestType.held_message:
            print(f"""\
Sender:  {data['_mod_sender']}
Subject: {data['_mod_subject']}
Date:    {data['_mod_hold_date']}
Reason:  {data['_mod_reason']}
""")
        elif request_type in (RequestType.subscription, RequestType.unsubscription):
            print(f"""\
{request_type.name}: {data}
""")
        else:
            raise Exception(f"Unknown request type: {request_type}")

    if request_ids:
        input(_fmt(f"There are {len(request_ids)} unhandled {request_type.name} requests, press Enter to remove, or CTRL+C to abort...", Colors.yellow))
        print("Discarding...", end="")
        for request_id in request_ids:
            if request_type == RequestType.held_message:
                handle_message(m, request_id, Action.discard)
            else:
                requestdb.delete_request(request_id)
            print(f" {request_id}", end="")
        print("")


def close_list(m, archive='nochange'):
    _mod_queue(m, RequestType.held_message)
    _mod_queue(m, RequestType.subscription)
    _mod_queue(m, RequestType.unsubscription)

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
