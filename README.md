This is a long-retired script developed to automate the lifecycle of Mac computers at a large scale.

It has an interactive text console with defaults and timeouts (zero interaction required) and supports installing a Mac OS, a Windows OS, or both, as well as secure erasing and other disk maintenance tasks.

A few unique features of this script:
- The image data is distributed using bittorrent. A dedicated seeder and web host (for the torrent file) is required.
- The imaging workflow checks the machine serial number against an inventory database to prevent accidental destruction of non-owned machined (as this boot utility was advertised on many shared campus networks via BOOTP)

To use this script:

(very rough, from memory, as I don't recall exactly how this part was done):

- Create a NetBoot image
- Open/convert the image read/write
- Install transmisson-cli and this script
- Modify an /etc/rc* file to open Terminal.app and load this script
- Copy a few required frameworks (at least ruby, there were a few others) into the System folder
- Reconvert to read-only as scan as requie for netboot
- Configure NetBoot to use this image
