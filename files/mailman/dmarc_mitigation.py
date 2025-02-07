# run with:
#   mailman shell -r dmarc_mitigation
from mailman.interfaces.listmanager import IListManager
from mailman.interfaces.mailinglist import DMARCMitigateAction
from zope.component import getUtility


def dmarc_mitigation():
    for m in getUtility(IListManager).mailing_lists:
        if m.dmarc_mitigate_action != DMARCMitigateAction.munge_from:
            print(f"{m.list_id}: Updated {m.dmarc_mitigate_action} -> {DMARCMitigateAction.munge_from}")
            m.dmarc_mitigate_action = DMARCMitigateAction.munge_from
