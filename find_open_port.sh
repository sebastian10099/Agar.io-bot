$(function findOpenPort() {
    let openPorts = [];
    for (let i = 1; i <= 65535; i++) {
        if (!isPortInUse(i)) {
            openPorts.push(i);
        }
    }
    return openPorts;
})

function isPortInUse(port) {
    const socket = new WebSocket(`ws://localhost:${port}`);
    try {
        socket.send('test');
    } catch (error) {
        return true;
    }
    socket.close();
    return false;
}

findOpenPort()