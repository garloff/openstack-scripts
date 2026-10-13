# Script collection for managing OpenStack

This is what I built over the years dealing with KVM and OpenStack.

## Image Registration

This takes a .qcow2 image, optionally converts it to raw (`--raw`)
and interactively asks for some properties and then uploads it to OpenStack
(as determined by `OS_CLOUD`). Needs qemu-img and of course openstack client
tools installed.

* [imgreg.sh](imgreg.sh)

## List VMs

This goes through the process list and spots the qemu processes, extracting
a few useful bits from the command line, such as instance-id, uuid, MAC
address and spice port.

* [qemu-list](qemu-list)

## Detect OpenStack versions

This queries the service catalog and does version and microversion (and
extensions) discovery. Can be useful to get an impression what a provider
really offers.

* [api-list.sh](api-list.sh)

## Cleanup stale placement allocations

After one of my nodes crashed, `openstack resource provider inventory list $HYPEID`
listed too much memory and VCPU consumption. My placement allocation table apparently
had gotten out of sync with reality. Fixing it in the database did not seem very
sustainable, so I created this script, with a little help from Qwen3.8-27B. (In the
end, it did not save much time, but I still avoided looking up a few things ...)
You can run it safely (with admin credentials), as it defaults to `--dry-run`.

* [cleanup-placement-allocation.py](cleanup-placement-allocation.py)

Note that `nova-manage placement audit --verbose` does a similar thing
(add `--delete` to really clean up). `nova-manage placement heal_allocations`
can be used to add missing allocations.
