//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2021 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

import XCTest
import BlinkFiles
import Combine
import Dispatch

@testable import SSH


class SFTPTests: XCTestCase {
  var cancellableBag: [AnyCancellable] = []
  
  override func setUpWithError() throws {
    // Put setup code here. This method is called before the invocation of each test method in the class.
    SSHInit()
  }
  
  override func tearDownWithError() throws {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
  }
  
  func testRequest() throws {
    // TODO Share credentials between tests
    let config = SSHClientConfig(user: "carlos", authMethods: [AuthPassword(with: "")])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    var sftp: SFTPClient?
    let cancellable = SSHClient.dial("localhost", with: config)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        print("Received connection")
        connection = conn
        // We should throw immediately
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<[[FileAttributeKey : Any]], Error> in
        sftp = client
        return client.directoryFilesAndAttributes()
      }.assertNoFailure()
      .sink { list in
        dump(list)
        expectation.fulfill()
      }
    
    waitForExpectations(timeout: 15, handler: nil)
  }
  
  func testRead() throws {
    // TODO Share credentials between tests
    let config = SSHClientConfig(user: "carlos", authMethods: [AuthPassword(with: "")])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    var sftp: SFTPClient?
    
    let cancellable = SSHClient.dial("localhost", with: config)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        print("Received connection")
        connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<Translator, Error> in
        sftp = client
        return client.walkTo("mosh.pkg")
      }.flatMap() { item -> AnyPublisher<File, Error> in
        return item.open(flags: O_RDONLY)
      }.flatMap() { file in
        return file.read(max: SSIZE_MAX)
      }
      .assertNoFailure()
      .sink { data in
        print(">>>> \(data.count)")
        
        if data.count <= 0 {
          XCTFail("Nothing received")
        }
        expectation.fulfill()
      }
    
    waitForExpectations(timeout: 15, handler: nil)
  }
  
  func testWriteTo() throws {
    // TODO Share credentials between tests
    let config = SSHClientConfig(user: "carlos", authMethods: [AuthPassword(with: "")])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    var sftp: SFTPClient?
    let buffer = MemoryBuffer(fast: true)
    var totalWritten = 0
    
    let cancellable = SSHClient.dial("localhost", with: config)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        print("Received connection")
        connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<Translator, Error> in
        sftp = client
        // TODO Create a random file first, or use one from a previous test.
        return client.walkTo("Xcode_12.0.1.xip")
      }.flatMap() { item -> AnyPublisher<File, Error> in
        return item.open(flags: O_RDONLY)
      }.flatMap() { f -> AnyPublisher<Int, Error> in
        let file = f as! SFTPFile
        return file.writeTo(buffer)
      }.assertNoFailure()
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          expectation.fulfill()
        case .failure(let error):
          // Problem here is we can have both SFTP and SSHError
          XCTFail("Crash")
        }
      }, receiveValue: { written in
        totalWritten += written
      })
    
    waitForExpectations(timeout: 15000, handler: nil)
    XCTAssertTrue(totalWritten == 11210638916, "Wrote \(totalWritten)")
    print("TOTAL \(totalWritten)")
  }
  
  func testWrite() throws {
    let config = SSHClientConfig(user: "carlos", authMethods: [AuthPassword(with: "")])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    var sftp: SFTPClient?
    var totalWritten = 0
    
    let gen = RandomInputGenerator(fast: true)
    
    let cancellable = SSHClient.dial("localhost", with: config)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        print("Received connection")
        connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<Translator, Error> in
        sftp = client
        return client.walkTo("/tmp")
      }.flatMap() { dir -> AnyPublisher<File, Error> in
        return dir.create(name: "newfile", flags: O_WRONLY, mode: S_IRWXU)
      }.flatMap() { file in
        return gen.read(max: 5 * 1024 * 1024)
          .flatMap() { data in
            return file.write(data, max: data.count)
          }
      }.sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          expectation.fulfill()
        case .failure(let error):
          // Problem here is we can have both SFTP and SSHError
          if let err = error as? SSH.FileError {
            XCTFail(err.description)
          } else {
            XCTFail("Crash")
          }
        }
      }, receiveValue: { written in
        totalWritten += written
      })
    
    waitForExpectations(timeout: 15, handler: nil)
    XCTAssert(totalWritten == 5 * 1024 * 1024, "Did not write all data")
  }
  
  func testWriteToWriter() throws {
    let config = SSHClientConfig(user: "carlos", authMethods: [AuthPassword(with: "")])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    var sftp: SFTPClient?
    let buffer = MemoryBuffer(fast: true)
    var totalWritten = 0
    
    let cancellable = SSHClient.dial("localhost", with: config)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        print("Received connection")
        connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<File, Error> in
        sftp = client
        // TODO Create a random file first, or use one from a previous test.
        return client.walkTo("Xcode_12.0.1.xip")
          .flatMap { $0.open(flags: O_RDONLY) }.eraseToAnyPublisher()
      }.flatMap() { f -> AnyPublisher<Int, Error> in
        let file = f as! SFTPFile
        return sftp!.walkTo("/tmp/")
          .flatMap { $0.create(name: "Xcode.xip", flags: O_WRONLY, mode: S_IRWXU) }
          .flatMap() { file.writeTo($0) }.eraseToAnyPublisher()
      }.sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          expectation.fulfill()
        case .failure(let error):
          // Problem here is we can have both SFTP and SSHError
          XCTFail("Crash")
        }
      }, receiveValue: { written in
        totalWritten += written
      })
    
    waitForExpectations(timeout: 15000, handler: nil)
    XCTAssertTrue(totalWritten == 11210638916, "Wrote \(totalWritten)")
    print("TOTAL \(totalWritten)")
    // TODO Cleanup
  }
  
  func testRemove() throws {
    let config = SSHClientConfig(user: "carlos", authMethods: [AuthPassword(with: "")])
    
    let expectation = self.expectation(description: "Removed")
    
    var connection: SSHClient?
    var sftp: SFTPClient?
    let buffer = MemoryBuffer(fast: true)
    var totalWritten = 0
    
    let cancellable = SSHClient.dial("localhost", with: config)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        print("Received connection")
        connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<Translator, Error> in
        return client.walkTo("/tmp/tmpfile")
      }.flatMap() { file in
        return file.remove()
      }
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          print("done")
        case .failure(let error as SSH.FileError):
          XCTFail(error.description)
        case .failure(let error):
          XCTFail("Unknown")
        }
      }, receiveValue: { result in
        XCTAssertTrue(result)
        expectation.fulfill()
      })
    
    waitForExpectations(timeout: 5, handler: nil)
  }
  
  // func testMkdir() throws {
  //     let config = SSHClientConfig(user: "carlos", authMethods: [AuthPassword(with: "")])
  
  //     let expectation = self.expectation(description: "Removed")
  
  //     var connection: SSHClient?
  //     var sftp: SFTPClient?
  //     let buffer = MemoryBuffer(fast: true)
  //     var totalWritten = 0
  
  //     let cancellable = SSHClient.dial("localhost", with: config)
  //         .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
  //             print("Received connection")
  //             connection = conn
  //             return conn.requestSFTP()
  //         }.flatMap() { client -> AnyPublisher<SFTPClient, Error> in
  //             return client.walkTo("/tmp/tmpfile")
  //         }.flatMap() { file in
  //             return file.remove()
  //         }
  //         .sink(receiveCompletion: { completion in
  //             switch completion {
  //             case .finished:
  //                 print("done")
  //             case .failure(let error):
  //                 XCTFail(dump(error))
  //             }
  //         }, receiveValue: { result in
  //             XCTAssertTrue(result)
  //             expectation.fulfill()
  //         })
  
  //     waitForExpectations(timeout: 5, handler: nil)
  //     connection?.close()
  // }
  // }
  
  func testCopyAsSource() throws {
    continueAfterFailure = false
    let config = SSHClientConfig(user: "carlos", authMethods: [AuthPassword(with: "")])
    
    var connection: SSHClient?
    var sftp: SFTPClient?
    let local = Local()
    
    let copied = self.expectation(description: "Copied structure")
    SSHClient.dial("localhost", with: config)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        print("Received connection")
        connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<Translator, Error> in
        sftp = client
        // TODO Create a random file first, or use one from a previous test.
        return client.walkTo("playgrounds")
      }.flatMap() { f -> CopyProgressInfo in
        return local.walkTo("/tmp/test").flatMap { $0.copy(from: [f]) }.eraseToAnyPublisher()
      }.sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          print("done")
          copied.fulfill()
        case .failure(let error):
          XCTFail("\(error)")
        }
      }, receiveValue: { result in
        dump(result)
        //totalWritten += result[1]
      }).store(in: &cancellableBag)
    
    wait(for: [copied], timeout: 500)
  }
  
  func testCopyAsDest() throws {
    let config = SSHClientConfig(user: "carlos", authMethods: [AuthPassword(with: "")])
    
    var connection: SSHClient?
    var sftp: SFTPClient?
    let local = Local()
    
    let copied = self.expectation(description: "Copied structure")
    SSHClient.dial("localhost", with: config)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        print("Received connection")
        connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<Translator, Error> in
        sftp = client
        // TODO Create a random file first, or use one from a previous test.
        return client.walkTo("/tmp/test")
      }.flatMap() { f -> CopyProgressInfo in
        return local.walkTo("/Users/carlos/playgrounds").flatMap { f.copy(from: [$0]) }.eraseToAnyPublisher()
      }.sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          print("done")
          copied.fulfill()
        case .failure(let error):
          XCTFail("\(error)")
        }
      }, receiveValue: { result in
        dump(result)
        //totalWritten += result[1]
      }).store(in: &cancellableBag)
    
    wait(for: [copied], timeout: 500)
  }
  
  // Write and read a stat
  func testStat() throws {
    
  }
}
